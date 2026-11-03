// Copied from the reference CRM.
import { monthDay } from "../../../shared/crm/task-page";
import { localFromInput } from "../../../shared/crm/local-time";
import { useEffect, useMemo, useRef, useState } from "react";
import { AtSign, Bell, CalendarClock, ChevronDown, ChevronLeft, ChevronRight, Camera, ListFilter, Loader2, Paperclip, Plus, Search, SendHorizontal, Smile, Upload, UserRound, Video, X, BellOff, Check, UserPlus } from "lucide-react";
import { cn } from "../lib/utils";
// Local: the shortcut is spelt for this machine by the app's keymap, never a hand-typed Mac glyph.
import { formatChord } from "../../keymap";
import { AnchoredPopover } from "../anchored-popover";
import { PersonAvatar } from "../people/person-picker";
import { DictateButton } from "../ui/dictate-button";
import { ActivityFeed, FEED_CATEGORIES, type CommentActions, type FeedCategory } from "../activity-feed";
import { PersonSearchList } from "../person-search-list";
import { screenshotName } from "../use-file-drop";
import { schedulePresets, type CommentExtras } from "../../../shared/crm/task-comments";
import { TaskTextField, type InlineFileInfo, type TaskTextFieldHandle } from "../task-text-field";
import { peopleList } from "../task-collab-draft";
import type { TaskActivityRow } from "../../../shared/crm/task-activity";
import type { TaskAttachment, TaskPeople } from "../../../shared/crm/collab-types";
import type { TaskAssignee, TaskComment } from "../../../shared/crm/tasks-data";

/**
 * THE ACTIVITY PANE — ClickUp's right-hand 560px column (inventory § 2.0,
 * § 2.10; Asad's screenshot 2026-09-15):
 *
 *   Activity                                  🔍  🔔 n  ≡
 *   (empty space — the feed is anchored to the bottom)
 *   • You created this task                        7 mins
 *   …comment cards…
 *   ┌───────────────────────────────────────────────────┐
 *   │ Write a comment…                                   │
 *   │ ⊕ │ 📎 @ ☺                               🎤  ➤    │
 *   └───────────────────────────────────────────────────┘
 *
 * ⊕ is ClickUp's "Slash commands" — the task actions a comment box can run
 * (assign, priority, dates, status, close, subtask, move, relationships) and
 * the mention; "/" in an empty box opens the same panel. 📎 uploads to the task
 * and places the file in the comment; 🎥 records a clip and ⧉ takes a
 * screenshot (only where the browser can capture a screen); 👤 assigns the
 * comment and Send ⌄ schedules it for later (both only once
 * migrations/2026-09-15-task-comments.sql is there — until then they are not
 * offered). The comment card's reply / react / resolve live in activity-feed.tsx.
 * Not here: ClickUp's "Comment ⌄" and "✓" — the explorer has not yet recorded
 * what they hold — and "📄 Create Doc", which has no Docs to create here.
 */

/** What a send carries beyond the words: a reply's thread, an assignee, a scheduled time. */
export type PostOptions = { parentId?: string | null; assigneeUserId?: string | null; scheduledFor?: string | null };

export type SlashOption = { key: string; label: string; icon?: React.ReactNode; run: () => void };
export type SlashCommand = {
  key: string;
  group: "INLINE" | "TASK ACTIONS";
  label: string;
  icon: React.ComponentType<{ className?: string }>;
  run?: () => void;
  options?: SlashOption[];
};

const EMOJI = ["👍", "👏", "🙏", "🎉", "✅", "❌", "⚠️", "🔥", "❤️", "💯", "😀", "😂", "😅", "😊", "😍", "🤔", "😮", "😢", "😡", "👀", "🚀", "📌", "📎", "📅", "⏰", "🏠", "🔑", "💰", "📞", "✉️", "🤝", "💪"];

export function ActivityPane({
  taskId,
  viewerId,
  team,
  people,
  activity,
  activityError,
  activityTotal = null,
  comments,
  commentsError,
  attachments,
  onPost,
  commands,
  onAttachFiles,
  fileOf,
  commentExtras = null,
  commentActions,
  followers = null,
  iFollow = true,
  onFollow,
  onAddFollower,
  onRemoveFollower,
  canRemoveFollowers = false,
  followersUnavailable = null,
}: {
  taskId: string;
  viewerId: string;
  team: TaskAssignee[];
  people: TaskPeople | null;
  activity: TaskActivityRow[] | null;
  activityError: string | null;
  /** Every line the task has — the read returns the newest 500; past that the pane says "the latest n of N" (MCP coverage r2). */
  activityTotal?: number | null;
  comments: TaskComment[] | null;
  commentsError: string | null;
  attachments: TaskAttachment[] | null;
  onPost: (body: string, opts?: PostOptions) => Promise<boolean>;
  commands: SlashCommand[];
  /** The comment card's footer data — null until (or unless) the comments migration is there. */
  commentExtras?: CommentExtras | null;
  /** React · Resolve · Send now; Reply is the pane's own. */
  commentActions?: Omit<CommentActions, "reply">;
  /** 🔔 — the followers (part 2), the caller's choice and its save; null = not available (yet). */
  followers?: { userId: string; since: string | null }[] | null;
  iFollow?: boolean;
  onFollow?: (following: boolean) => void;
  onAddFollower?: (personId: string) => void;
  /** Take someone off the followers (removeFollower); × shows for yourself always, for others only with canRemoveFollowers. */
  onRemoveFollower?: (personId: string) => void;
  canRemoveFollowers?: boolean;
  followersUnavailable?: string | null;
  /** Files from the comment box's 📎 — uploaded to the task; each resolves to the chip placed in the comment. */
  onAttachFiles?: (files: File[]) => Promise<{ id: string; info: InlineFileInfo }[]>;
  fileOf: (id: string) => InlineFileInfo | null;
}) {
  const [searchOpen, setSearchOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [hidden, setHidden] = useState<ReadonlySet<FeedCategory>>(() => new Set());
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [replyingTo, setReplyingTo] = useState<string | null>(null);
  const cardActions: CommentActions | undefined =
    commentExtras && commentActions ? { ...commentActions, reply: (id) => setReplyingTo((cur) => (cur === id ? null : id)) } : undefined;

  // Newest against the composer: stay pinned to the bottom as lines arrive.
  const count = (activity?.length ?? 0) + (comments?.length ?? 0);
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [count]);

  return (
    <aside className="flex min-h-0 flex-col border-l border-slate-200 bg-[#fafafa]" data-testid="task-page-activity" aria-label="Activity">
      <div className="flex h-12 shrink-0 items-center gap-1 border-b border-slate-200 px-4">
        <span className="flex-1 text-sm font-semibold text-slate-800">Activity</span>
        <button
          type="button"
          onClick={() => {
            setSearchOpen((o) => !o);
            setQuery("");
          }}
          aria-label="Search activity"
          aria-pressed={searchOpen}
          className="grid h-7 w-7 place-content-center rounded-md text-slate-500 hover:bg-slate-200/60 hover:text-slate-800"
        >
          <Search className="h-4 w-4" aria-hidden />
        </button>
        <FollowersBell
          people={people}
          team={team}
          followers={followers}
          iFollow={iFollow}
          onFollow={onFollow}
          onAddFollower={onAddFollower}
          onRemoveFollower={onRemoveFollower}
          viewerId={viewerId}
          canRemoveOthers={canRemoveFollowers}
          unavailable={followersUnavailable}
        />
        <FilterMenu hidden={hidden} onChange={setHidden} />
      </div>
      {searchOpen && (
        <div className="flex items-center gap-2 border-b border-slate-200 px-4 py-2">
          <Search className="h-3.5 w-3.5 text-slate-400" aria-hidden />
          <input
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                setSearchOpen(false);
                setQuery("");
              }
            }}
            placeholder="Search activity"
            aria-label="Search activity text"
            className="w-full bg-transparent text-sm outline-none placeholder:text-slate-400"
          />
        </div>
      )}
      <div ref={scrollRef} className="flex min-h-0 flex-1 flex-col overflow-y-auto">
        <div className="mt-auto">
          {activityError && (
            <div className="mx-4 mt-3 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-100" role="status">
              Activity unavailable: {activityError}
            </div>
          )}
          {commentsError && <div className="mx-4 mt-3 text-xs text-rose-600">Could not load comments: {commentsError}</div>}
          {activity && activityTotal !== null && activityTotal > activity.length && (
            <div className="mx-4 mt-3 text-xs text-slate-500" role="status" data-testid="activity-cut">
              Showing the latest {activity.length} of {activityTotal.toLocaleString("en-US")} lines.
            </div>
          )}
          {activity === null ? (
            <div className="flex items-center gap-2 px-5 py-3 text-xs text-slate-400">
              <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden /> Loading…
            </div>
          ) : (
            <ActivityFeed
              rows={activity}
              comments={comments ?? []}
              viewerId={viewerId}
              team={team}
              taskId={taskId}
              attachments={attachments}
              query={query}
              hidden={hidden}
              commentExtras={commentExtras}
              commentActions={cardActions}
              replyingTo={replyingTo}
              replyBox={
                replyingTo ? (
                  <ReplyBox
                    key={replyingTo}
                    team={team}
                    fileOf={fileOf}
                    onCancel={() => setReplyingTo(null)}
                    onSend={async (body) => {
                      const ok = await onPost(body, { parentId: replyingTo });
                      if (ok) setReplyingTo(null);
                      return ok;
                    }}
                  />
                ) : null
              }
            />
          )}
        </div>
      </div>
      <Composer
        team={team}
        fileOf={fileOf}
        hasComments={(comments?.length ?? 0) > 0}
        onPost={onPost}
        commands={commands}
        onAttachFiles={onAttachFiles}
        rich={!!commentExtras}
      />
    </aside>
  );
}

/** 🔔 n — who hears about this task: the people on it. */
/**
 * 🔔 FOLLOWERS (inventory § 2.0 / § 4): the count on the bell; the popover's
 * Follow — "Notify me on all activity for this task." · Unfollow — "Notify me
 * only on @mentions or assignment." (the caller's own choice, ✓ on the
 * current one), a search, the followers with since when, and "Add" for anyone
 * typed who is not following. Before migrations/2026-09-15-task-page-2.sql
 * the choice cannot be saved: everyone on the task is notified, and it says so.
 */
export function FollowersBell({
  people,
  team,
  followers,
  iFollow = true,
  onFollow,
  onAddFollower,
  onRemoveFollower,
  viewerId = null,
  canRemoveOthers = false,
}: {
  people: TaskPeople | null;
  team: TaskAssignee[];
  followers?: { userId: string; since: string | null }[] | null;
  iFollow?: boolean;
  onFollow?: (following: boolean) => void;
  onAddFollower?: (personId: string) => void;
  /** Remove a follower — offered exactly where the server allows it: yourself, or anyone when `canRemoveOthers` (round 7, V1). */
  onRemoveFollower?: (personId: string) => void;
  viewerId?: string | null;
  canRemoveOthers?: boolean;
  unavailable?: string | null;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const everyone = people ? peopleList(people) : [];
  const byId = new Map(team.map((p) => [p.id, p]));
  const list = followers
    ? followers.map((f) => ({ id: f.userId, person: byId.get(f.userId) ?? everyone.find((e) => e.id === f.userId) ?? null, since: f.since }))
    : everyone.map((p) => ({ id: p.id, person: p, since: null as string | null }));
  const n = list.length;
  const words = q.trim().toLowerCase();
  const shown = words ? list.filter((f) => (f.person?.name ?? "").toLowerCase().includes(words)) : list;
  const addable = words && onAddFollower ? team.filter((p) => p.name.toLowerCase().includes(words) && !list.some((f) => f.id === p.id)).slice(0, 5) : [];
  const choice = (on: boolean) =>
    cn("flex w-full items-start gap-2.5 rounded-md px-2 py-1.5 text-left", on ? "bg-violet-50 text-violet-800" : "text-slate-700 hover:bg-slate-50");
  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label={`${n} ${n === 1 ? "follower" : "followers"} will get notified`}
        title={`${n} ${n === 1 ? "follower" : "followers"} will get notified`}
        className="inline-flex h-7 items-center gap-0.5 rounded-md px-1.5 text-violet-600 hover:bg-slate-200/60"
      >
        <Bell className="h-4 w-4" aria-hidden />
        <span className="text-sm font-medium">{n}</span>
      </button>
      <AnchoredPopover
        anchorRef={ref}
        open={open}
        onClose={() => {
          setOpen(false);
          setQ("");
        }}
        label="Followers"
        width={290}
        align="right"
      >
        <div className="p-2" data-testid="followers-panel">
          {followers && onFollow ? (
            <div role="radiogroup" aria-label="Notifications for this task" className="space-y-0.5">
              <button type="button" role="radio" aria-checked={iFollow} onClick={() => !iFollow && onFollow(true)} className={choice(iFollow)}>
                <Bell className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                <span className="flex-1">
                  <span className="block text-sm font-medium">Follow</span>
                  <span className="block text-xs text-slate-500">Notify me on all activity for this task.</span>
                </span>
                {iFollow && <Check className="mt-0.5 h-4 w-4 text-violet-600" aria-hidden />}
              </button>
              <button type="button" role="radio" aria-checked={!iFollow} onClick={() => iFollow && onFollow(false)} className={choice(!iFollow)}>
                <BellOff className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                <span className="flex-1">
                  <span className="block text-sm font-medium">Unfollow</span>
                  <span className="block text-xs text-slate-500">Notify me only on @mentions or assignment.</span>
                </span>
                {!iFollow && <Check className="mt-0.5 h-4 w-4 text-violet-600" aria-hidden />}
              </button>
            </div>
          ) : (
            <p className="px-1 text-[11px] leading-snug text-amber-700" data-testid="followers-unavailable">
              {/* Before the migration there is no following: everyone on the task hears everything (inc8 M4 — no developer file named). */}
              Everyone on this task is notified.
            </p>
          )}
          <div className="my-2 border-t border-slate-100" aria-hidden />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search Followers..."
            aria-label="Search followers"
            className="h-8 w-full rounded-md border border-slate-200 px-2 text-sm outline-none focus:border-violet-500"
          />
          <div className="px-1 pb-1 pt-2 text-[11px] text-slate-500">
            {n} {n === 1 ? "follower" : "followers"}
          </div>
          <ul className="max-h-56 space-y-0.5 overflow-y-auto">
            {shown.map((f) => (
              <li key={f.id} className="flex items-center gap-2 rounded px-1 py-1 text-sm text-slate-800">
                {f.person ? <PersonAvatar name={f.person.name} initials={f.person.initials} color={f.person.color} avatarUrl={f.person.avatarUrl} size="xs" /> : <span className="h-5 w-5 rounded-full bg-slate-200" />}
                <span className="min-w-0 flex-1 truncate">{f.person?.name ?? "Someone"}</span>
                {f.since && <span className="text-[11px] text-slate-400">since {monthDay(f.since)}</span>}
                {followers && onRemoveFollower && (canRemoveOthers || f.id === viewerId) && (
                  <button
                    type="button"
                    onClick={() => onRemoveFollower(f.id)}
                    aria-label={`Remove ${f.person?.name ?? "this person"} from followers`}
                    title="Remove from followers"
                    className="grid h-5 w-5 shrink-0 place-content-center rounded text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                  >
                    <X className="h-3 w-3" aria-hidden />
                  </button>
                )}
              </li>
            ))}
          </ul>
          {addable.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => {
                onAddFollower?.(p.id);
                setQ("");
              }}
              className="mt-0.5 flex w-full items-center gap-2 rounded px-1 py-1 text-left text-sm text-slate-700 hover:bg-slate-50"
            >
              <UserPlus className="h-4 w-4 text-slate-400" aria-hidden />
              Add {p.name}
            </button>
          ))}
        </div>
      </AnchoredPopover>
    </>
  );
}

/** ≡ "Filter activity" — which kinds of line the feed shows. */
function FilterMenu({ hidden, onChange }: { hidden: ReadonlySet<FeedCategory>; onChange: (next: ReadonlySet<FeedCategory>) => void }) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const active = hidden.size > 0;
  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label="Filter activity"
        aria-expanded={open}
        className={cn("grid h-7 w-7 place-content-center rounded-md hover:bg-slate-200/60", active ? "text-violet-600" : "text-slate-500 hover:text-slate-800")}
      >
        <ListFilter className="h-4 w-4" aria-hidden />
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Filter activity" width={260} align="right">
        <div className="p-2" data-testid="activity-filter">
          <div className="flex items-center px-1 pb-1.5">
            <span className="flex-1 text-xs font-medium text-slate-500">Show</span>
            <button type="button" onClick={() => onChange(new Set())} className="rounded px-1.5 py-0.5 text-xs text-violet-700 hover:bg-violet-50">
              All
            </button>
            <button
              type="button"
              onClick={() => onChange(new Set(FEED_CATEGORIES.map((c) => c.key).filter((k) => k !== "comments")))}
              className="rounded px-1.5 py-0.5 text-xs text-violet-700 hover:bg-violet-50"
            >
              Comments only
            </button>
          </div>
          {FEED_CATEGORIES.map((c) => (
            <label key={c.key} className="flex cursor-pointer items-center gap-2 rounded px-1 py-1 text-sm text-slate-700 hover:bg-slate-50">
              <input
                type="checkbox"
                checked={!hidden.has(c.key)}
                onChange={(e) => {
                  const next = new Set(hidden);
                  if (e.target.checked) next.delete(c.key);
                  else next.add(c.key);
                  onChange(next);
                }}
                className="h-3.5 w-3.5 accent-violet-600"
              />
              {c.label}
            </label>
          ))}
        </div>
      </AnchoredPopover>
    </>
  );
}

function ToolBtn({ label, onClick, children, btnRef, expanded }: { label: string; onClick?: () => void; children: React.ReactNode; btnRef?: React.Ref<HTMLButtonElement>; expanded?: boolean }) {
  return (
    <button
      ref={btnRef}
      type="button"
      onClick={onClick}
      aria-label={label}
      title={label}
      aria-expanded={expanded}
      className="grid h-6 w-7 place-content-center rounded text-slate-500 hover:bg-slate-100 hover:text-slate-800"
    >
      {children}
    </button>
  );
}

/** The comment box: a rounded card, the text, the toolbar under it (ClickUp § 2.10). */
function Composer({
  team,
  fileOf,
  hasComments,
  onPost,
  commands,
  onAttachFiles,
  rich,
}: {
  team: TaskAssignee[];
  fileOf: (id: string) => InlineFileInfo | null;
  hasComments: boolean;
  onPost: (body: string, opts?: PostOptions) => Promise<boolean>;
  commands: SlashCommand[];
  onAttachFiles?: (files: File[]) => Promise<{ id: string; info: InlineFileInfo }[]>;
  /** The comments migration is there: 👤 assign comment and Send ⌄ "Schedule for later" are offered. */
  rich: boolean;
}) {
  const [value, setValue] = useState("");
  const [posting, setPosting] = useState(false);
  const textRef = useRef<TaskTextFieldHandle | null>(null);
  const slashRef = useRef<HTMLButtonElement | null>(null);
  const [slashOpen, setSlashOpen] = useState(false);
  const clipRef = useRef<HTMLButtonElement | null>(null);
  const [clipOpen, setClipOpen] = useState(false);
  const fileInput = useRef<HTMLInputElement | null>(null);
  const emojiRef = useRef<HTMLButtonElement | null>(null);
  const [emojiOpen, setEmojiOpen] = useState(false);
  const [uploading, setUploading] = useState(false);

  const [assignee, setAssignee] = useState<TaskAssignee | null>(null);
  const assignRef = useRef<HTMLButtonElement | null>(null);
  const [assignOpen, setAssignOpen] = useState(false);
  const laterRef = useRef<HTMLButtonElement | null>(null);
  const [laterOpen, setLaterOpen] = useState(false);
  const [capture, setCapture] = useState({ screen: false, record: false });
  useEffect(() => {
    const md = typeof navigator !== "undefined" ? navigator.mediaDevices : undefined;
    const screen = !!md && typeof md.getDisplayMedia === "function";
    setCapture({ screen, record: screen && typeof MediaRecorder !== "undefined" });
  }, []);
  const recorder = useRef<MediaRecorder | null>(null);
  const [recording, setRecording] = useState(false);

  async function send(scheduledFor?: string) {
    const body = value.trim();
    if (!body || posting) return;
    setPosting(true);
    const opts: PostOptions | undefined = assignee || scheduledFor ? { assigneeUserId: assignee?.id ?? null, scheduledFor: scheduledFor ?? null } : undefined;
    const ok = await onPost(body, opts);
    setPosting(false);
    if (ok) {
      setValue("");
      setAssignee(null);
    }
  }

  /** ⧉ — one frame of a screen, window or tab the person picks, as a PNG in the comment. */
  async function screenshot() {
    try {
      const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
      const video = document.createElement("video");
      video.srcObject = stream;
      video.muted = true;
      await video.play();
      await new Promise((r) => setTimeout(r, 150));
      const canvas = document.createElement("canvas");
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      canvas.getContext("2d")?.drawImage(video, 0, 0);
      stream.getTracks().forEach((t) => t.stop());
      const blob: Blob | null = await new Promise((r) => canvas.toBlob(r, "image/png"));
      if (blob) await attach([new File([blob], screenshotName(new Date()), { type: "image/png" })]);
    } catch {
      /* the person closed the picker — nothing to do */
    }
  }

  /** 🎥 — ClickUp's "Record Video Clip": the screen (and mic), until Stop or until sharing ends. */
  async function toggleRecording() {
    if (recording) {
      recorder.current?.stop();
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
      const rec = new MediaRecorder(stream, MediaRecorder.isTypeSupported("video/webm") ? { mimeType: "video/webm" } : undefined);
      const chunks: Blob[] = [];
      rec.ondataavailable = (e) => {
        if (e.data.size) chunks.push(e.data);
      };
      rec.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        setRecording(false);
        recorder.current = null;
        const blob = new Blob(chunks, { type: "video/webm" });
        if (blob.size) void attach([new File([blob], screenshotName(new Date(), "webm").replace("Screenshot", "Clip"), { type: "video/webm" })]);
      };
      stream.getVideoTracks()[0]?.addEventListener("ended", () => {
        if (rec.state !== "inactive") rec.stop();
      });
      recorder.current = rec;
      rec.start();
      setRecording(true);
    } catch {
      setRecording(false);
    }
  }

  async function attach(files: File[]) {
    if (!onAttachFiles || !files.length) return;
    setUploading(true);
    const placed = await onAttachFiles(files);
    setUploading(false);
    for (const p of placed) textRef.current?.insertFile(p.id, p.info);
  }

  return (
    <div className="shrink-0 px-3 pb-3 pt-2">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void send();
        }}
        className="rounded-[10px] border border-slate-200 bg-white shadow-sm focus-within:border-slate-300"
        data-testid="comment-composer"
      >
        <TaskTextField
          ref={textRef}
          value={value}
          onChange={setValue}
          team={team}
          onMention={() => undefined}
          fileOf={fileOf}
          maxVisible={1500}
          placeholder={hasComments ? "Comment or type '/' for commands" : "Write a comment..."}
          ariaLabel="Write a comment"
          onSubmit={() => void send()}
          onSlash={() => setSlashOpen(true)}
          className="block max-h-48 min-h-[44px] w-full px-5 pb-1 pt-3 text-sm leading-relaxed text-slate-800"
        />
        {assignee && (
          <div className="mx-4 mb-1 inline-flex items-center gap-1.5 rounded-full bg-violet-50 py-0.5 pl-1 pr-1.5 text-xs text-violet-800" data-testid="comment-assign-chip">
            <PersonAvatar name={assignee.name} initials={assignee.initials} color={assignee.color} avatarUrl={assignee.avatarUrl} size="xs" />
            Assign to {assignee.name}
            <button type="button" aria-label="Don't assign this comment" onClick={() => setAssignee(null)} className="rounded-full p-0.5 hover:bg-violet-100">
              <X className="h-3 w-3" aria-hidden />
            </button>
          </div>
        )}
        <div className="flex h-[38px] items-center gap-0.5 px-2 pb-1">
          <button
            ref={slashRef}
            type="button"
            onClick={() => setSlashOpen((o) => !o)}
            aria-label="Slash commands"
            title="Slash commands (/)"
            aria-expanded={slashOpen}
            className="grid h-6 w-6 place-content-center rounded-full bg-slate-100 text-slate-600 hover:bg-slate-200"
          >
            <Plus className="h-3.5 w-3.5" aria-hidden />
          </button>
          <span className="mx-1.5 h-4 w-px bg-slate-200" aria-hidden />
          {onAttachFiles && (
            <>
              <input
                ref={fileInput}
                type="file"
                multiple
                hidden
                aria-hidden
                tabIndex={-1}
                onChange={(e) => {
                  const files = Array.from(e.target.files ?? []);
                  e.target.value = "";
                  void attach(files);
                }}
              />
              <ToolBtn label="Attach a file to the comment" btnRef={clipRef} expanded={clipOpen} onClick={() => setClipOpen((o) => !o)}>
                {uploading ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Paperclip className="h-4 w-4" aria-hidden />}
              </ToolBtn>
              <AnchoredPopover anchorRef={clipRef} open={clipOpen} onClose={() => setClipOpen(false)} label="Attach" width={200}>
                <div role="menu">
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setClipOpen(false);
                      fileInput.current?.click();
                    }}
                    className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50"
                  >
                    <Upload className="h-4 w-4 text-slate-500" aria-hidden />
                    Upload file
                  </button>
                </div>
              </AnchoredPopover>
            </>
          )}
          <ToolBtn label="Mention someone" onClick={() => textRef.current?.startMention()}>
            <AtSign className="h-4 w-4" aria-hidden />
          </ToolBtn>
          {rich && (
            <>
              <ToolBtn label="Assign comment" btnRef={assignRef} expanded={assignOpen} onClick={() => setAssignOpen((o) => !o)}>
                <UserRound className="h-4 w-4" aria-hidden />
              </ToolBtn>
              <AnchoredPopover anchorRef={assignRef} open={assignOpen} onClose={() => setAssignOpen(false)} label="Assign comment" width={280}>
                <PersonSearchList
                  team={team}
                  isPicked={(id) => id === assignee?.id}
                  onPick={(p) => {
                    setAssignee(p.id === assignee?.id ? null : p);
                    setAssignOpen(false);
                  }}
                />
              </AnchoredPopover>
            </>
          )}
          <ToolBtn label="Emoji" btnRef={emojiRef} expanded={emojiOpen} onClick={() => setEmojiOpen((o) => !o)}>
            <Smile className="h-4 w-4" aria-hidden />
          </ToolBtn>
          <AnchoredPopover anchorRef={emojiRef} open={emojiOpen} onClose={() => setEmojiOpen(false)} label="Emoji" width={264}>
            <div className="grid grid-cols-8 gap-0.5 p-2" data-testid="emoji-picker">
              {EMOJI.map((em) => (
                <button
                  key={em}
                  type="button"
                  onClick={() => {
                    setEmojiOpen(false);
                    textRef.current?.insertText(em);
                  }}
                  className="grid h-7 w-7 place-content-center rounded text-lg hover:bg-slate-100"
                  aria-label={`Insert ${em}`}
                >
                  {em}
                </button>
              ))}
            </div>
          </AnchoredPopover>
          {onAttachFiles && capture.record && (
            <ToolBtn label={recording ? "Stop recording" : "Record video clip"} onClick={() => void toggleRecording()}>
              {recording ? <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-rose-500" aria-hidden /> : <Video className="h-4 w-4" aria-hidden />}
            </ToolBtn>
          )}
          {onAttachFiles && capture.screen && (
            <ToolBtn label="Take a screenshot" onClick={() => void screenshot()}>
              <Camera className="h-4 w-4" aria-hidden />
            </ToolBtn>
          )}
          <span className="ml-auto" />
          <DictateButton title="Dictate a comment" onTranscript={(t) => textRef.current?.insertText(`${t} `)} />
          <span className="ml-1 inline-flex overflow-hidden rounded-md">
            <button
              type="submit"
              disabled={!value.trim() || posting}
              aria-label="Send comment"
              title={`Send (${formatChord("mod+enter")})`}
              className="grid h-[26px] w-[34px] place-content-center bg-violet-600 text-white hover:bg-violet-700 disabled:bg-slate-100 disabled:text-slate-400"
            >
              {posting ? <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden /> : <SendHorizontal className="h-3.5 w-3.5" aria-hidden />}
            </button>
            {rich && (
              <button
                ref={laterRef}
                type="button"
                disabled={!value.trim() || posting}
                onClick={() => setLaterOpen((o) => !o)}
                aria-label="Schedule for later"
                title="Schedule for later"
                aria-expanded={laterOpen}
                className="grid h-[26px] w-[20px] place-content-center border-l border-white/30 bg-violet-600 text-white hover:bg-violet-700 disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-400"
              >
                <ChevronDown className="h-3 w-3" aria-hidden />
              </button>
            )}
          </span>
        </div>
      </form>
      {rich && (
        <AnchoredPopover anchorRef={laterRef} open={laterOpen} onClose={() => setLaterOpen(false)} label="Schedule for later" width={264} align="right">
          <SchedulePanel
            onPick={(iso) => {
              setLaterOpen(false);
              void send(iso);
            }}
          />
        </AnchoredPopover>
      )}
      <AnchoredPopover anchorRef={slashRef} open={slashOpen} onClose={() => setSlashOpen(false)} label="Slash commands" width={440}>
        <SlashPanel
          commands={commands}
          onMention={() => {
            setSlashOpen(false);
            textRef.current?.startMention();
          }}
          onDone={() => setSlashOpen(false)}
        />
      </AnchoredPopover>
    </div>
  );
}

/** ClickUp's "/" panel: search, then groups of commands; a command with choices opens them in place. */
function SlashPanel({ commands, onMention, onDone }: { commands: SlashCommand[]; onMention: () => void; onDone: () => void }) {
  const [q, setQ] = useState("");
  const [sub, setSub] = useState<SlashCommand | null>(null);
  const all: SlashCommand[] = useMemo(
    () => [{ key: "mention", group: "INLINE", label: "Mention a Person", icon: AtSign, run: onMention }, ...commands],
    [commands, onMention],
  );
  const needle = q.trim().toLowerCase();
  const list = all.filter((c) => !needle || c.label.toLowerCase().includes(needle));
  const groups = (["INLINE", "TASK ACTIONS"] as const).map((g) => ({ g, items: list.filter((c) => c.group === g) })).filter((x) => x.items.length);
  const tile = "grid h-6 w-6 shrink-0 place-content-center rounded border border-slate-200 bg-white text-slate-600";
  return (
    <div className="max-h-[408px] overflow-y-auto p-2" data-testid="slash-panel">
      {sub ? (
        <>
          <button type="button" onClick={() => setSub(null)} className="mb-1 flex items-center gap-1 px-1 text-xs font-medium text-slate-500 hover:text-slate-800">
            <ChevronLeft className="h-3.5 w-3.5" aria-hidden />
            {sub.label}
          </button>
          {sub.options?.map((o) => (
            <button
              key={o.key}
              type="button"
              onClick={() => {
                o.run();
                onDone();
              }}
              className="flex h-9 w-full items-center gap-2.5 rounded px-2 text-left text-sm text-slate-800 hover:bg-slate-50"
            >
              {o.icon && <span className={tile}>{o.icon}</span>}
              {o.label}
            </button>
          ))}
        </>
      ) : (
        <>
          <div className="mb-1 flex items-center gap-2 rounded-md border border-slate-200 px-2 py-1.5">
            <Search className="h-3.5 w-3.5 text-slate-400" aria-hidden />
            <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search" aria-label="Search commands" className="w-full bg-transparent text-sm outline-none" />
            {q && (
              <button type="button" aria-label="Clear search" onClick={() => setQ("")} className="text-slate-400 hover:text-slate-700">
                <X className="h-3.5 w-3.5" aria-hidden />
              </button>
            )}
          </div>
          {groups.length === 0 && <p className="px-2 py-2 text-xs text-slate-400">No command matches.</p>}
          {groups.map(({ g, items }) => (
            <div key={g} className="mt-1">
              <div className="px-2 pb-0.5 pt-1.5 text-[11px] font-medium uppercase tracking-wide text-slate-400">{g === "INLINE" ? "Inline" : "Task actions"}</div>
              {items.map((c) => {
                const Icon = c.icon;
                return (
                  <button
                    key={c.key}
                    type="button"
                    onClick={() => {
                      if (c.options) setSub(c);
                      else {
                        c.run?.();
                        if (c.key !== "mention") onDone();
                      }
                    }}
                    className="flex h-9 w-full items-center gap-2.5 rounded px-2 text-left text-sm text-slate-800 hover:bg-slate-50"
                  >
                    <span className={tile}>
                      <Icon className="h-3.5 w-3.5" />
                    </span>
                    <span className="flex-1">{c.label}</span>
                    {c.options && <ChevronRight className="h-3.5 w-3.5 text-slate-400" aria-hidden />}
                  </button>
                );
              })}
            </div>
          ))}
        </>
      )}
    </div>
  );
}


/**
 * Send ⌄ "Schedule for later" (inventory § 2.10): a time field, then ClickUp's
 * presets with the moment each resolves to. Choosing one sends the comment for
 * that moment — only its author sees it until then.
 */
function SchedulePanel({ onPick }: { onPick: (iso: string) => void }) {
  const [custom, setCustom] = useState("");
  const presets = schedulePresets();
  // The typed time is this computer's, like the presets beside it.
  const customAt = localFromInput(custom);
  const customOk = !!customAt && customAt.getTime() > Date.now();
  return (
    <div className="p-2" data-testid="schedule-panel">
      <div className="mb-1 flex items-center gap-1.5">
        <input
          type="datetime-local"
          value={custom}
          onChange={(e) => setCustom(e.target.value)}
          aria-label="Pick a time"
          title="Your computer's time"
          className="h-8 min-w-0 flex-1 rounded-md border border-slate-200 px-2 text-sm focus:border-violet-500 focus:outline-none"
        />
        <span className="shrink-0 text-xs text-slate-500">Local</span>
        <button
          type="button"
          disabled={!customOk}
          onClick={() => customAt && onPick(customAt.toISOString())}
          className="h-8 rounded-md bg-violet-600 px-2.5 text-xs font-medium text-white disabled:opacity-40"
        >
          Schedule
        </button>
      </div>
      {presets.map((p) => (
        <button
          key={p.key}
          type="button"
          onClick={() => onPick(p.at.toISOString())}
          className="flex h-8 w-full items-center gap-2 rounded px-2 text-left text-sm text-slate-800 hover:bg-slate-50"
        >
          <CalendarClock className="h-3.5 w-3.5 text-slate-400" aria-hidden />
          <span className="flex-1">{p.label}</span>
          <span className="text-xs text-slate-500">{p.hint}</span>
        </button>
      ))}
    </div>
  );
}

/** The Reply box under a thread: the same editor, Cancel / Reply. */
function ReplyBox({
  team,
  fileOf,
  onSend,
  onCancel,
}: {
  team: TaskAssignee[];
  fileOf: (id: string) => InlineFileInfo | null;
  onSend: (body: string) => Promise<boolean>;
  onCancel: () => void;
}) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const go = async () => {
    const body = value.trim();
    if (!body || busy) return;
    setBusy(true);
    const ok = await onSend(body);
    setBusy(false);
    if (ok) setValue("");
  };
  return (
    <div className="rounded-lg border border-slate-200 bg-white" data-testid="reply-box">
      <TaskTextField
        value={value}
        onChange={setValue}
        team={team}
        onMention={() => undefined}
        fileOf={fileOf}
        maxVisible={1500}
        autoFocus
        placeholder="Reply…"
        ariaLabel="Write a reply"
        onSubmit={() => void go()}
        onEscape={onCancel}
        className="block max-h-40 min-h-[36px] w-full px-3 pb-1 pt-2 text-sm text-slate-800"
      />
      <div className="flex justify-end gap-1.5 px-2 pb-2">
        <button type="button" onClick={onCancel} className="h-7 rounded-md px-2.5 text-xs text-slate-600 hover:bg-slate-100">
          Cancel
        </button>
        <button type="button" disabled={!value.trim() || busy} onClick={() => void go()} className="h-7 rounded-md bg-violet-600 px-2.5 text-xs font-medium text-white disabled:opacity-40">
          Reply
        </button>
      </div>
    </div>
  );
}
