export default {
  fetch(request) {
    const url = new URL(request.url);
    url.hostname = "harness.codegraff.com";
    return Response.redirect(url.toString(), 301);
  },
};
