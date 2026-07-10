const DEFAULT_HOSTNAME = "tethershot.pages.dev";
const CUSTOM_ORIGIN = "https://tethershot.apoorvdarshan.com";

export function onRequest(context) {
  const incoming = new URL(context.request.url);

  if (incoming.hostname === DEFAULT_HOSTNAME) {
    const destination = new URL(incoming.pathname + incoming.search, CUSTOM_ORIGIN);
    return Response.redirect(destination, 308);
  }

  return context.next();
}
