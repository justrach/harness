//! Draw harness-tui's first-run setup by itself.
//!
//!   harness-tui-setup                 ask, with the engine's real answers, and save them
//!   harness-tui-setup --step N        open on step N (0-4) and save nothing
//!   harness-tui-setup --print N       print step N as text and exit

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |name: &str| {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).and_then(|v| v.parse::<usize>().ok())
    };
    if arg("--step").is_none() && arg("--print").is_none() {
        harness_tui_setup::run(None, true).await;
        return;
    }
    let mut engine = harness_tui_setup::Engine::connect().await;
    let mut state = harness_tui_setup::load(&mut engine).await;
    if let Some(n) = arg("--print") {
        state.step = n.min(harness_tui_setup::QUESTIONS);
        println!("{}", harness_tui_setup::plain(&harness_tui_setup::frame(&state)));
        return;
    }
    state.step = arg("--step").unwrap_or(0).min(harness_tui_setup::QUESTIONS);
    let _ = harness_tui_setup::ask(&mut state);
}
