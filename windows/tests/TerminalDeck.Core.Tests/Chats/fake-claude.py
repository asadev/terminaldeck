"""Synthetic stream-json CLI. Never reads a provider home or calls a model."""
import json
import sys

conversation = sys.argv[1]
pending = None
active = None

def emit(value):
    # Split writes inside a UTF-8 code point to exercise incremental decoding.
    payload = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8")
    split = payload.find("🙂".encode("utf-8")) + 1
    if split > 0:
        sys.stdout.buffer.write(payload[:split]); sys.stdout.buffer.flush()
        sys.stdout.buffer.write(payload[split:]); sys.stdout.buffer.flush()
    else:
        sys.stdout.buffer.write(payload); sys.stdout.buffer.flush()

def complete():
    emit({"type": "result", "subtype": "success", "is_error": False, "session_id": conversation})

def answer(text, identity):
    message = "assistant:" + identity
    emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": message}}})
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Reply 🙂 "}}})
    emit({"type": "assistant", "message": {"id": message, "content": [{"type": "text", "text": "Reply 🙂 " + text}]}})
    complete()

emit({"type": "system", "subtype": "init", "session_id": conversation})
for line in sys.stdin:
    row = json.loads(line)
    if row.get("type") == "user":
        active = row["uuid"]
        content = row["message"]["content"]
        text = next((item["text"] for item in content if item["type"] == "text"), "image")
        emit({"type": "user", "uuid": active, "message": {"content": content}})
        if text == "hold":
            continue
        if text == "approval":
            pending = (active, "request:" + active)
            emit({"type": "control_request", "request_id": pending[1], "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {"file_path": "synthetic.txt", "content": "synthetic"}}})
            continue
        answer(text, active)
    elif row.get("type") == "control_response" and pending:
        allowed = row["response"]["response"]["behavior"] == "allow"
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "synthetic-tool", "content": "allowed" if allowed else "refused"}]}})
        answer("allowed" if allowed else "refused", pending[0]); pending = None
    elif row.get("type") == "control_request" and row.get("request", {}).get("subtype") == "interrupt":
        complete()
