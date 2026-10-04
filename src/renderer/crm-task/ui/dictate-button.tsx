// Copied from the reference CRM.
import { useEffect, useRef, useState } from "react";
import { Mic, Square } from "lucide-react";
import { cn } from "../lib/utils";

/**
 * SPEAK INTO A FIELD, ON THIS DEVICE.
 *
 * Asad, 2026-09-14: *"give a mic button inside for speaking inside and then
 * click for rewrite. 1st we can have speech to text but using local mic options
 * not ai"*.
 *
 * So this is the browser's own Web Speech API — the same one
 * components/ai/smart-search.tsx already uses for the ⌘K box. Nothing is sent
 * to our AI provider and nothing is billed: the transcription is the browser's,
 * and on Chrome it is the platform's speech service. The AI step is the
 * SEPARATE button next to it, pressed afterwards, exactly as he described.
 *
 * 🔴 IT HIDES ITSELF WHERE IT CANNOT WORK. The API is Chrome/Safari-only
 * (Firefox has no implementation). A mic that renders everywhere and does
 * nothing in Firefox is a control that refuses — which this project forbids by
 * name — so support is checked after mount and the button simply is not there
 * when the browser has no recogniser.
 *
 * Support is read in an EFFECT, not during render: `window` does not exist on
 * the server, and reading it inline makes the first client render disagree with
 * the server's HTML (hydration mismatch).
 */

// Minimal typings for the Web Speech API — it is not in lib.dom for every
// target. Same shim as smart-search.tsx, widened for continuous dictation.
type SpeechAlternative = { transcript: string };
type SpeechResult = { isFinal: boolean; 0: SpeechAlternative; length: number };
type SpeechResultEvent = { resultIndex: number; results: { length: number; [i: number]: SpeechResult } };
type SpeechRecognitionLike = {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  start: () => void;
  stop: () => void;
  onresult: (e: SpeechResultEvent) => void;
  onend: () => void;
  onerror: (e: { error?: string }) => void;
};

type SpeechCtor = new () => SpeechRecognitionLike;

function recogniser(): SpeechCtor | null {
  if (typeof window === "undefined") return null;
  // Local: inside the app the browser's recogniser exists but has no speech service behind it and fails
  // on its first word, so — by the rule above (hidden where it cannot work) — the mic is not offered here.
  if (/Electron\//.test(navigator.userAgent)) return null;
  const w = window as unknown as { SpeechRecognition?: SpeechCtor; webkitSpeechRecognition?: SpeechCtor };
  return w.SpeechRecognition || w.webkitSpeechRecognition || null;
}

export function DictateButton({
  onTranscript,
  className,
  lang = "en-US",
  title = "Dictate",
}: {
  /** Called with each FINAL phrase. The caller decides where it lands. */
  onTranscript: (text: string) => void;
  className?: string;
  lang?: string;
  title?: string;
}) {
  const [supported, setSupported] = useState(false);
  const [listening, setListening] = useState(false);
  const [denied, setDenied] = useState(false);
  const recRef = useRef<SpeechRecognitionLike | null>(null);
  // The callback changes identity on every keystroke of the parent's state;
  // holding it in a ref keeps the live recogniser bound to the latest one
  // without tearing down and restarting dictation mid-sentence.
  const cbRef = useRef(onTranscript);
  cbRef.current = onTranscript;

  useEffect(() => {
    setSupported(!!recogniser());
    return () => {
      // Never leave the microphone open behind a closed dialog.
      try { recRef.current?.stop(); } catch { /* already stopped */ }
      recRef.current = null;
    };
  }, []);

  function stop() {
    try { recRef.current?.stop(); } catch { /* already stopped */ }
    recRef.current = null;
    setListening(false);
  }

  function start() {
    const Ctor = recogniser();
    if (!Ctor) return;
    const rec = new Ctor();
    rec.lang = lang;
    // Continuous, because this fills a TEXTAREA — a task is several sentences,
    // and the one-shot mode the ⌘K search uses would cut after the first.
    rec.continuous = true;
    rec.interimResults = false;
    rec.onresult = (ev) => {
      let out = "";
      for (let i = ev.resultIndex; i < ev.results.length; i++) {
        const r = ev.results[i];
        if (r?.isFinal) out += r[0]?.transcript ?? "";
      }
      const trimmed = out.trim();
      if (trimmed) cbRef.current(trimmed);
    };
    rec.onend = () => { recRef.current = null; setListening(false); };
    rec.onerror = (e) => {
      // "not-allowed" is the browser's permission refusal. Saying so beats a
      // mic that silently does nothing after it was pressed.
      if (e?.error === "not-allowed" || e?.error === "service-not-allowed") setDenied(true);
      recRef.current = null;
      setListening(false);
    };
    recRef.current = rec;
    setListening(true);
    setDenied(false);
    try { rec.start(); } catch { setListening(false); }
  }

  if (!supported) return null;

  return (
    <button
      type="button"
      onClick={() => (listening ? stop() : start())}
      aria-pressed={listening}
      aria-label={listening ? "Stop dictating" : title}
      title={denied ? "Microphone blocked — allow it in your browser's address bar" : listening ? "Stop dictating" : title}
      className={cn(
        "inline-flex h-7 w-7 items-center justify-center rounded-md border transition-colors",
        listening
          ? "border-rose-200 bg-rose-50 text-rose-600"
          : denied
            ? "border-slate-200 bg-white text-slate-300"
            : "border-slate-200 bg-white text-slate-500 hover:bg-slate-50 hover:text-slate-700",
        className,
      )}
    >
      {listening ? <Square className="h-3.5 w-3.5 fill-current" /> : <Mic className="h-3.5 w-3.5" />}
    </button>
  );
}
