/**
 * Where the popup's layers go.
 *
 * The reference CRM portals its dialog, popovers, pickers and lightbox to
 * `<body>`. Here they go to one element under `<body>` that carries the
 * popup's root class, because every rule in the popup's stylesheet is scoped
 * under that class — so nothing of the CRM's look reaches the rest of the app,
 * and everything the popup opens still gets it.
 */
export const ROOT_CLASS = "crm-task-root";

export function portalRoot(): HTMLElement {
  const found = document.querySelector<HTMLElement>(`body > .${ROOT_CLASS}[data-portal]`);
  if (found) return found;
  const el = document.createElement("div");
  el.className = ROOT_CLASS;
  el.dataset.portal = "";
  document.body.appendChild(el);
  return el;
}
