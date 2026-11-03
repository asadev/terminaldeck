// Copied from the reference CRM.
/**
 * Are the upload + serve routes for task attachments in place?
 *
 * TRUE since 2026-09-15 (backlog A7): POST /api/tasks/[id]/attachments puts
 * the bytes in the private company-drive bucket and records the row;
 * GET /api/tasks/[id]/attachments/[attachmentId] answers a 60-second signed
 * URL behind the same taskAccess gate. With this true every attachments
 * control offers BOTH doors — "Upload from device" and "Link from Files"
 * (Asad, 2026-09-14: "it should give both options").
 *
 * Kept as a flag rather than deleted: flipping it back hides every upload
 * control in one line if the routes ever have to come down, without leaving a
 * button that renders and then refuses.
 */
export const UPLOADS_WIRED = true;
