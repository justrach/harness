# Browser on Linux

The sidebar browser uses the distribution's WebKitGTK 4.1 runtime. On Ubuntu or Debian, install it with:

```sh
sudo apt install libwebkit2gtk-4.1-0 libjson-glib-1.0-0
```

Zeron starts its browser helper when a page is first opened. The main application does not link to GTK or WebKit, so other app features remain available if the browser runtime is missing. WebKit runs in a separate process and uses an ephemeral website-data context shared by the open tabs.

The helper sends live offscreen frames to GPUI, which draws the page alongside the rest of the app. Both X11 and Wayland use this path, including clipping, sidebar transitions, tooltips, and frosted overlays. It uses CPU-addressable frames rather than embedding a separate native browser window. Animated pages therefore incur frame-copy and texture-upload work.

For development, install `libwebkit2gtk-4.1-dev` and `libjson-glib-dev` in addition to the normal GPUI build dependencies. The build embeds the small helper executable, which is extracted to the user's cache directory when needed. WebKit itself stays system-managed and receives security updates through the distribution.
