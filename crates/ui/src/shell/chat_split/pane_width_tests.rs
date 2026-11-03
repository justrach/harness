//! Side-by-side panes hold still when focus moves between them. The focused pane used to take
//! whatever width the others left, dividers included, so it was a pixel per divider narrower
//! than its share; moving focus moved every pane in between (7 px across eight panes), which
//! looked like the window shaking while you clicked from pane to pane to type.
use super::*;
use gpui::{Bounds, Pixels, TestAppContext, VisualTestContext};

const WIDTH: f32 = 1600.0;

struct SplitHost(Entity<Shell>);

impl Render for SplitHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let shell = self.0.clone();
        let split = shell.update(cx, |shell, cx| {
            shell.render_chat_split(div().size_full().into_any_element(), cx)
        });
        div().w(px(WIDTH)).h(px(600.0)).flex().child(split)
    }
}

fn setup<'a>(
    cx: &'a mut TestAppContext,
    path: &std::path::Path,
) -> (Entity<Shell>, &'a mut VisualTestContext) {
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        settings::init(settings::UiSettings::default(), path, cx);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        let shell = cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            Shell::new(
                state,
                EngineBootConfig {
                    data_dir: path.into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            )
        });
        SplitHost(shell)
    });
    let shell = host.read_with(cx, |host, _| host.0.clone());
    (shell, cx)
}

fn panes(cx: &mut VisualTestContext, count: usize) -> Vec<Bounds<Pixels>> {
    cx.update(|window, cx| window.draw(cx).clear());
    (0..count)
        .map(|ix| {
            cx.debug_bounds(Box::leak(format!("chat-split-pane-{ix}").into_boxed_str()))
                .unwrap()
        })
        .collect()
}

#[gpui::test]
fn moving_focus_between_side_by_side_panes_moves_no_pane(cx: &mut TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = setup(cx, dir.path());
    let count = cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            for _ in 0..7 {
                shell.split_chat(SplitAxis::Horizontal, window, cx);
            }
            shell
                .chat_split
                .as_ref()
                .map_or(1, |split| split.panes.len())
        })
    });
    assert!(count >= 4, "a split of several panes, got {count}");
    let first_focused = {
        cx.update(|window, cx| shell.update(cx, |shell, cx| shell.focus_chat_pane(0, window, cx)));
        panes(cx, count)
    };
    for focus in 1..count {
        cx.update(|window, cx| {
            shell.update(cx, |shell, cx| shell.focus_chat_pane(focus, window, cx))
        });
        let now = panes(cx, count);
        for (ix, (before, after)) in first_focused.iter().zip(&now).enumerate() {
            assert_eq!(
                (before.left(), before.size.width),
                (after.left(), after.size.width),
                "pane {ix} moved when focus went from pane 0 to pane {focus}"
            );
        }
    }
    // The panes and their dividers fill the column exactly.
    let last = first_focused.last().unwrap();
    assert!(
        (f32::from(last.right()) - WIDTH).abs() < 0.5,
        "panes end at {:?}",
        last.right()
    );
}
