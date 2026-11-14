//! Local queue operations share one SessionDoc across application workers.
//! Rendezvous each race on a nonempty queue: a startup-only barrier or an
//! empty queue misses the stale-position append that automatic delivery exposed.

use std::sync::{Arc, Barrier};
use std::thread;

use crate::{QueueDeliveryGate, QueuedMessage, SessionDoc};

const ROUNDS: usize = 256;

#[derive(Clone, Copy, Debug)]
enum Publish {
    Push,
    InsertPastEnd,
}

#[derive(Clone, Copy, Debug)]
enum Consume {
    Take,
    Remove,
}

#[test]
fn concurrent_push_and_insert_with_take_or_removal_preserve_every_row() {
    for publication in [Publish::Push, Publish::InsertPastEnd] {
        for consumption in [Consume::Take, Consume::Remove] {
            for round in 0..ROUNDS {
                let doc = Arc::new(SessionDoc::init("queue-position-race").unwrap());
                let old = QueuedMessage::new("old", "already waiting", "fixture");
                let new = QueuedMessage::new("new", format!("accepted {round}"), "fixture");
                doc.push_queued(&old).unwrap();
                let start = Arc::new(Barrier::new(2));
                let (published, consumed) = thread::scope(|scope| {
                    let producer_doc = doc.clone();
                    let producer_start = start.clone();
                    let new = &new;
                    let producer = scope.spawn(move || {
                        producer_start.wait();
                        match publication {
                            Publish::Push => producer_doc.push_queued(new),
                            Publish::InsertPastEnd => producer_doc.insert_queued(usize::MAX, new),
                        }
                    });
                    let consumer_doc = doc.clone();
                    let consumer_start = start.clone();
                    let consumer = scope.spawn(move || {
                        consumer_start.wait();
                        match consumption {
                            Consume::Take => consumer_doc.take_queued("old"),
                            Consume::Remove => consumer_doc.remove_queued("old").map(|removed| {
                                assert!(removed, "the designated old row must exist");
                                None
                            }),
                        }
                    });
                    (producer.join().unwrap(), consumer.join().unwrap())
                });
                published.unwrap_or_else(|error| {
                    panic!("{publication:?}/{consumption:?} round {round}: {error:?}")
                });
                let taken = consumed.expect("concurrent consumption must not use a stale index");
                match consumption {
                    Consume::Take => assert_eq!(taken, Some(old)),
                    Consume::Remove => assert!(taken.is_none()),
                }
                assert_eq!(
                    doc.read_queue().unwrap(),
                    vec![new.clone()],
                    "{publication:?}/{consumption:?} round {round}: no lost or duplicate rows"
                );
                assert_eq!(doc.take_queue_head().unwrap(), Some(new));
                assert!(doc.take_queue_head().unwrap().is_none());
            }
        }
    }
}

#[test]
fn concurrent_takers_return_a_row_exactly_once() {
    for round in 0..ROUNDS {
        let doc = Arc::new(SessionDoc::init("queue-take-race").unwrap());
        let expected = QueuedMessage::new("shared", format!("take once {round}"), "fixture");
        let survivor = QueuedMessage::new("survivor", "must not be taken instead", "fixture");
        doc.push_queued(&expected).unwrap();
        doc.push_queued(&survivor).unwrap();
        let start = Arc::new(Barrier::new(4));
        let taken = thread::scope(|scope| {
            let workers: Vec<_> = (0..4)
                .map(|_| {
                    let doc = doc.clone();
                    let start = start.clone();
                    scope.spawn(move || {
                        start.wait();
                        doc.take_queued("shared")
                    })
                })
                .collect();
            workers
                .into_iter()
                .filter_map(|worker| {
                    worker
                        .join()
                        .unwrap()
                        .expect("another taker winning must return None, not an error")
                })
                .collect::<Vec<_>>()
        });
        assert_eq!(taken, vec![expected], "round {round}: only one owner");
        assert_eq!(doc.read_queue().unwrap(), vec![survivor]);
    }
}

#[test]
fn concurrent_removal_move_and_edit_keep_mutations_on_the_requested_id() {
    for round in 0..ROUNDS {
        let doc = Arc::new(SessionDoc::init("queue-edit-move-race").unwrap());
        let removed = QueuedMessage::new("removed", "remove only this row", "fixture");
        let mut edited = QueuedMessage::new("edited", "before edit", "fixture");
        let untouched = QueuedMessage::new("untouched", "leave this row alone", "fixture");
        for row in [&removed, &edited, &untouched] {
            doc.push_queued(row).unwrap();
        }
        let start = Arc::new(Barrier::new(3));
        let (removed, moved, changed) = thread::scope(|scope| {
            let remove_doc = doc.clone();
            let remove_start = start.clone();
            let remover = scope.spawn(move || {
                remove_start.wait();
                remove_doc.remove_queued("removed")
            });
            let move_doc = doc.clone();
            let move_start = start.clone();
            let mover = scope.spawn(move || {
                move_start.wait();
                move_doc.move_queued("edited", usize::MAX)
            });
            let edit_doc = doc.clone();
            let edit_start = start.clone();
            let editor = scope.spawn(move || {
                edit_start.wait();
                let changed = edit_doc.set_queued_text("edited", "intermediate edit", 100)?;
                assert!(changed);
                let gate = QueueDeliveryGate::ReviewRequired {
                    previous_lease_id: "synthetic-lease".into(),
                    owner_device_id: "fixture".into(),
                    since_ms: 100,
                    base_text_hash: "synthetic-hash".into(),
                };
                assert!(edit_doc.set_queued_delivery_gate("edited", Some(&gate))?);
                edit_doc.finish_queued_edit_with_attachments(
                    "edited",
                    Some("finished edit"),
                    Some(&["uploads/synthetic.png".into()]),
                    200,
                )
            });
            (
                remover.join().unwrap(),
                mover.join().unwrap(),
                editor.join().unwrap(),
            )
        });
        assert!(removed.expect("removal cannot race into another row"));
        assert!(moved.expect("move indices must stay valid until the move completes"));
        assert!(changed.expect("edit must remain attached to its requested ID"));
        edited.text = "finished edit".into();
        edited.edited_at = Some(200);
        edited.attachments = vec!["uploads/synthetic.png".into()];
        assert_eq!(
            doc.read_queue().unwrap(),
            vec![untouched, edited],
            "round {round}: order, metadata and cleared gate must survive removal"
        );
    }
}

#[test]
fn queue_commit_subscribers_can_read_and_reenter_without_the_mutation_guard_held() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    let doc = Arc::new(SessionDoc::init("queue-subscriber-reentry").unwrap());
    for id in ["edited", "other"] {
        doc.push_queued(&QueuedMessage::new(id, id, "fixture"))
            .unwrap();
    }
    let notifications = Arc::new(AtomicUsize::new(0));
    let observed = Arc::downgrade(&doc);
    let observed_notifications = notifications.clone();
    // Loro documents that subscription callbacks run when commit emits events.
    // Inspect the guard first so accidentally holding it fails immediately,
    // rather than hanging the suite on the reentrant operation below.
    let _subscription = doc.doc().subscribe_root(Arc::new(move |_| {
        let doc = observed.upgrade().expect("document lives through callback");
        let guard = doc
            .queue_mutation
            .try_lock()
            .expect("queue commit called its subscriber while holding the mutation guard");
        drop(guard);
        doc.read_queue().expect("subscriber can read the queue");
        // A missing-ID mutation acquires the same guard but does not commit:
        // exercise real reentry without generating recursive Loro events.
        assert!(!doc.remove_queued("never-present").unwrap());
        observed_notifications.fetch_add(1, Ordering::SeqCst);
    }));

    doc.push_queued(&QueuedMessage::new("pushed", "pushed", "fixture"))
        .unwrap();
    assert_eq!(notifications.load(Ordering::SeqCst), 1);
    doc.insert_queued(0, &QueuedMessage::new("inserted", "inserted", "fixture"))
        .unwrap();
    assert_eq!(notifications.load(Ordering::SeqCst), 2);
    assert!(doc.set_queued_text("edited", "updated", 100).unwrap());
    assert_eq!(notifications.load(Ordering::SeqCst), 3);
    let gate = QueueDeliveryGate::ReviewRequired {
        previous_lease_id: "synthetic-lease".into(),
        owner_device_id: "fixture".into(),
        since_ms: 100,
        base_text_hash: "synthetic-hash".into(),
    };
    assert!(doc.set_queued_delivery_gate("edited", Some(&gate)).unwrap());
    assert_eq!(notifications.load(Ordering::SeqCst), 4);
    assert!(
        doc.finish_queued_edit("edited", Some("finished"), 200)
            .unwrap()
    );
    assert_eq!(notifications.load(Ordering::SeqCst), 5);
    assert!(doc.move_queued("edited", usize::MAX).unwrap());
    assert_eq!(notifications.load(Ordering::SeqCst), 6);
    assert!(doc.remove_queued("inserted").unwrap());
    assert_eq!(notifications.load(Ordering::SeqCst), 7);
    assert_eq!(doc.take_queued("pushed").unwrap().unwrap().id, "pushed");
    assert_eq!(notifications.load(Ordering::SeqCst), 8);
    assert_eq!(doc.take_queue_head().unwrap().unwrap().id, "other");
    assert_eq!(notifications.load(Ordering::SeqCst), 9);
    assert!(doc.set_queued_text("edited", "", 300).unwrap());
    assert_eq!(notifications.load(Ordering::SeqCst), 10);
    assert!(doc.read_queue().unwrap().is_empty());
}
