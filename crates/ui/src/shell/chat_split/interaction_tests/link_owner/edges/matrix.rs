use super::*;

#[gpui::test]
fn every_pane_routes_to_its_owner_on_both_axes_up_to_the_pane_limit(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for count in [2, 3, MAX_CHAT_PANES] {
            for target in 0..count {
                with_panes(cx, vec![reply("Peer response")], |shell, _, _, cx| {
                    let names: Vec<String> = (0..count)
                        .map(|ix| match ix {
                            0 => "peer".into(),
                            1 => "current".into(),
                            _ => format!("extra-{ix}"),
                        })
                        .collect();
                    shell.update(cx, |shell, cx| {
                        shell.state.update(cx, |state, cx| {
                            for name in names.iter().skip(2) {
                                let mut chat = state.chats[0].clone();
                                chat.id = name.clone();
                                state.chats.push(chat);
                                let mut entry = reply("Extra peer response");
                                entry.id = format!("{name}-response");
                                state.set_subagent_snapshot(name.clone(), vec![entry]);
                            }
                            cx.notify();
                        });
                        let split = shell.chat_split.as_mut().unwrap();
                        split.axis = axis;
                        for name in names.iter().skip(2) {
                            split.panes.push(Some(name.clone()));
                            split.projects.push(None);
                            split.drafts.push(None);
                            split.vanished.push(None);
                            split.shares.push(0.0);
                        }
                        split.equalize();
                        shell.sync_chat_panes(cx);
                        shell.on_state_changed(&shell.state.clone(), cx);
                    });
                    cx.simulate_resize(match axis {
                        SplitAxis::Horizontal => gpui::size(px(480.0 * count as f32), px(640.0)),
                        SplitAxis::Vertical => gpui::size(px(960.0), px(320.0 * count as f32)),
                    });
                    draw(cx);
                    let view = shell.read_with(cx, |shell, _| {
                        if target == 1 {
                            shell.transcript.clone()
                        } else {
                            shell.peer_chat_views[&names[target]].transcript.clone()
                        }
                    });
                    let ui = links(&view, cx);
                    assert_eq!(ui.source_session.as_deref(), Some(names[target].as_str()));
                    for embedded_default in [false, true] {
                        cx.update(|_, cx| {
                            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                                settings.open_web_links_in_harness = embedded_default;
                            })
                        });
                        for action in [
                            LinkAction::Primary,
                            LinkAction::Internal,
                            LinkAction::External,
                        ] {
                            let internal = action == LinkAction::Internal
                                || (action == LinkAction::Primary && embedded_default);
                            cx.update(|window, cx| {
                                assert_eq!(
                                    (ui.handler)(&activation(&ui, action), window, cx),
                                    if internal {
                                        LinkOutcome::Internal
                                    } else {
                                        LinkOutcome::External(URL.into())
                                    }
                                );
                            });
                            shell.read_with(cx, |shell, _| {
                                assert_eq!(
                                    shell.active_chat,
                                    if internal {
                                        names[target].as_str()
                                    } else {
                                        "current"
                                    }
                                );
                                if internal {
                                    assert_eq!(shell.transcript, view);
                                    assert!(
                                        shell.right_tabs[&names[target]]
                                            .contains(&RightSurface::Browser(shell.browser_seq))
                                    );
                                }
                            });
                            if internal && target != 1 {
                                shell
                                    .update(cx, |shell, cx| assert!(shell.select_chat_pane(1, cx)));
                                draw(cx);
                            }
                        }
                    }
                    if target != 1 {
                        shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(target, cx)));
                    }
                    cx.update(|_, cx| {
                        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                            settings.open_web_links_in_harness = true
                        })
                    });
                    navigate(&shell, "matrix-next", cx);
                    shell.read_with(cx, |shell, _| assert_eq!(shell.transcript, view));
                    click_current_link(&shell, "matrix-next", cx);
                });
            }
        }
    }
}
