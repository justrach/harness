//! Isolated native Markdown evidence using synthetic math, prices and code.
//! Run with `--features appshots-fixture --example markdown-math-fixture -- DIR`.
use gpui::{
    AppContext, Bounds, Context, IntoElement, ParentElement, Render, Styled, Window, WindowBounds,
    WindowOptions, div, point, px, size,
};
use harness_ui::{appearance, icons, markdown, settings, theme, theme_library, typography};
use std::{path::PathBuf, sync::Arc, time::Duration};

const SOURCE: &str = r#"# Mathematical layout

Inline: $\frac{a+b}{n}$ and $\sqrt{x^2+y^2}$ stay with prose.

\[ \hat{\mu}=\frac{1}{n}\sum_{i=1}^{n}x_i \]

\[ M=\begin{bmatrix}a & b\\ c & d\end{bmatrix} \]

\[ \underbrace{wx}_{\text{weighted input}}+\underbrace{b}_{\text{bias}} \]

- Nested fraction: $\frac{1}{1+\frac{1}{x}}$; **$x_i^2$**.

| Quantity | Formula |
|---|---|
| Standard error | $\frac{\sigma}{\sqrt{m}}$ |

Prices stay literal: $5 and $10; $.50–$.75; escaped \$5.

Code stays literal: `$x^2$`.
"#;

const EDGE_SOURCE: &str = r#"# Math edge cases

Plain $x_i$ and **bold $x_i$**; [linked $x^2$](https://example.com/equation).

Decorations: ~~$x^2$~~ and **~~$\frac{a}{b}$~~**.

Nonbreaking: long token and narrow space beside $x$.

Long inline: $a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r+s+t+u+v+w+x+y+z$ then ordinary prose.

| Left | Center | Right |
|:---|:---:|---:|
| $x^2$ | $x^2$ | $x^2$ |

| Formula and media |
|---:|
| $x^2$ ![synthetic](synthetic.png) |

First line $x$ ends here.\
Next line $y$ begins here.

Unsupported input stays literal: $\unsupported{x}$.

Absolute spacing: $x\hspace{1pt}x$ and $x\hspace{1bp}x$.
"#;

const INK_SOURCE: &str = r#"# Equation ink boundaries

Controls: $x$ and $y$.

Leading negative space: $\hspace{-0.25em}x$.

Trailing negative space: $x\hspace{-0.25em}$.

Display: \[ \hspace{-0.25em}x+y \]
"#;

const SEMANTICS_SOURCE: &str = r#"# Typesetting fidelity

Ordinary fraction: $\frac{n}{k}$.

Binomial coefficient (no fraction bar): $\binom{n}{k}$.

Explicit display fraction: $\dfrac{a}{b}$.

Operator spacing control: $a+b$.

Explicit operator spacing: $a\hspace{0em}+b$.
"#;

const UNICODE_SOURCE: &str = r#"# Multilingual math flow

漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글漢字かなカナ한글 $x$.

Zero-width breaks: alpha​beta​gamma​delta​epsilon​zeta​eta​theta​iota​kappa​lambda​mu beside $y$.

Joined emoji: 👩**‍**💻; regional flag: 🇺**🇸** beside $z$.

Combining mark: e**́** beside $w$.

Nonbreaking controls: long token and narrow space beside $n$.
"#;

const BREAK_SOURCE: &str = concat!(
    "# Mandatory line breaks\n\n",
    "Line separator: first $x$\u{2028}second $y$.\n\n",
    "Paragraph separator: first $a$\u{2029}second $b$.\n\n",
    "Next-line control: first $m$\u{0085}second $n$.\n\n",
    "Code beside $q$: `left\u{2028}right`.\n\n",
    "Blank row: first $u$\u{2028}\u{2028}second $v$.\n\n",
    "Nonbreaking control: long\u{00a0}token beside $z$.\n",
);

const FILE_SOURCE: &str = r#"# Cheatsheet

Synthetic Week 9 notes · [Jump to formulas](#formulas)

## Formulas

Inline $\frac{a+b}{n}$ and \(\sqrt{x^2+y^2}\) stay with prose.

\[ M=\begin{bmatrix}a & b\\ c & d\end{bmatrix} \]

\[ \underbrace{wx}_{\text{weighted input}}+\underbrace{b}_{\text{bias}} \]

| Quantity | Formula |
|---|---:|
| Standard error | $\frac{\sigma}{\sqrt{m}}$ |

Literal controls: $5 and $10; `$x^2$`; $\unsupported{x}$.

```latex
\frac{a}{b} stays code
```
"#;

struct MathFixture {
    tree: markdown::BlockTree,
    preview: Option<gpui::AnyView>,
}

impl Render for MathFixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx);
        if let Some(preview) = &self.preview {
            return div()
                .size_full()
                .bg(theme.bg)
                .child(preview.clone())
                .into_any_element();
        }
        let mut opts = markdown::render::RenderOptions::settled("math-fixture".into());
        opts.media = Some(markdown::render::MediaUi {
            diagram: None,
            image: std::rc::Rc::new(|_, _, theme| {
                div()
                    .w(px(18.))
                    .h(px(18.))
                    .bg(theme.accent)
                    .into_any_element()
            }),
        });
        div()
            .size_full()
            .p(px(24.0))
            .bg(theme.bg)
            .text_color(theme.text)
            .child(markdown::render::render_tree(
                &self.tree,
                &opts,
                &theme,
                window,
                &|_| None,
            ))
            .into_any_element()
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let file_preview = std::env::args().any(|arg| arg == "--file-preview");
    let source = if file_preview {
        FILE_SOURCE
    } else if std::env::args().any(|arg| arg == "--breaks") {
        BREAK_SOURCE
    } else if std::env::args().any(|arg| arg == "--unicode") {
        UNICODE_SOURCE
    } else if std::env::args().any(|arg| arg == "--semantics") {
        SEMANTICS_SOURCE
    } else if std::env::args().any(|arg| arg == "--ink") {
        INK_SOURCE
    } else if std::env::args().any(|arg| arg == "--edges") {
        EDGE_SOURCE
    } else {
        SOURCE
    };
    let data = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let _runtime = runtime.enter();
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.path().to_owned(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family.clone(),
                settings.ui_font_size,
                settings.terminal_font_family.clone(),
                settings.terminal_font_size,
                settings.code_font_family.clone(),
                settings.code_font_size,
                fonts,
                cx,
            );
            theme_library::init(data.path().to_owned(), cx);
            appearance::init(
                appearance::AppearanceMode::Dark,
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            let windows: Vec<(gpui::AnyWindowHandle, &str)> =
                [(900.0, 720.0, "wide"), (480.0, 820.0, "narrow")]
                    .into_iter()
                    .map(|(width, height, name)| {
                        let window = cx
                            .open_window(
                                WindowOptions {
                                    window_background: theme::Theme::of(cx)
                                        .window_background_appearance(),
                                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                                        point(px(40.0), px(60.0)),
                                        size(px(width), px(height)),
                                    ))),
                                    ..Default::default()
                                },
                                |_, cx| {
                                    let preview = file_preview.then(|| {
                                        harness_ui::files::markdown_preview_fixture(source, cx)
                                    });
                                    cx.new(|_| MathFixture {
                                        tree: markdown::parse_full(source),
                                        preview,
                                    })
                                },
                            )
                            .unwrap();
                        (window.into(), name)
                    })
                    .collect();
            cx.activate(true);
            cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                for (window, name) in windows {
                    let capture: anyhow::Result<()> = (|| {
                        window.update(cx, |_, window, cx| {
                            window.draw(cx).clear();
                            window
                                .render_to_image()?
                                .save(output.join(format!("math-{name}.png")))?;
                            Ok(())
                        })?
                    })();
                    if let Err(error) = capture {
                        *result.lock().unwrap() = Some(format!("{error:#}"));
                    }
                    let _ = window.update(cx, |_, window, _| window.remove_window());
                }
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
