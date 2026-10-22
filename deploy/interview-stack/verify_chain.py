#!/usr/bin/env python3
"""
Stand-in servers to verify the n8n grader chain WITHOUT the real stack.

  :20128  OpenAI-compatible POST /v1/chat/completions   (9Router mock)
  :8484   GET  /api/v1/public/download/workflow/<t>/transcript  (dograh stand-in)
          POST /api/docs/*/tables/Interviews/records            (Grist mock)

Run on the host:  python3 verify_chain.py
n8n reaches both via host.docker.internal (the compose sets host-gateway).
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TRANSCRIPT = """Caller (Jane Doe): Hi, I can't log into my email. It keeps saying 'account locked'.
Agent: Good morning, thanks for calling the IT Help Desk, this is Alex. Sorry to hear that. Can I confirm your name and employee ID?
Caller: Jane Doe, ID 4821.
Agent: Thanks Jane. When did you first notice the lockout?
Caller: About an hour ago, after I entered the wrong password a few times.
Agent: Got it. I'll unlock the account now, but first let's make sure it's not a bigger issue. Are you on the office network?
Caller: Yes.
Agent: OK, I've reset the lockout. Can you try logging in now with your usual password?
Caller: It worked! I'm in.
Agent: Great. Since repeated wrong passwords caused this, I'd suggest a password reset to be safe. I can send you a reset link, or escalate to Tier 2 to force one. Also, can you confirm your ticket number 8842 so I can note the resolution?
Caller: Yes, 8842.
Agent: Perfect. I've documented the unlock and the recommendation. Anything else I can help with?
Caller: No, thank you!
Agent: You're welcome. Have a great day."""

GRADE = {
    "overall_score": 86,
    "verdict": "pass",
    "dimensions": {
        "greeting_and_professionalism": {"score": 5, "evidence": "Good morning, thanks for calling the IT Help Desk, this is Alex."},
        "active_listening_and_empathy": {"score": 5, "evidence": "Sorry to hear that. Can I confirm your name and employee ID?"},
        "issue_identification_and_triage": {"score": 4, "evidence": "When did you first notice the lockout?"},
        "troubleshooting_methodology": {"score": 4, "evidence": "I'll unlock the account now, but first let's make sure it's not a bigger issue."},
        "communication_clarity": {"score": 4, "evidence": "Can you try logging in now with your usual password?"},
        "escalation_judgment": {"score": 3, "evidence": "escalate to Tier 2 to force one"},
        "documentation_and_closure": {"score": 4, "evidence": "I've documented the unlock and the recommendation."}
    },
    "strengths": ["Strong structured greeting and identity confirmation", "Good clarification of scope before acting"],
    "improvements": ["Verify the caller is the account owner before unlocking", "Offer password reset proactively rather than as an aside", "Log exact steps tried in the ticket"],
    "summary": "Solid Tier 1 performance: professional, methodical, and closed the ticket properly. Slightly light on verification and proactive security guidance."
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _log(self, line):
        print(f"[{self.server.server_address[1]}] {line}", flush=True)

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._log(f"GET {self.path}")
        if self.path.startswith("/api/v1/public/download/workflow/"):
            body = TRANSCRIPT.encode("utf-8")
            self._send(200, body, "text/plain; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        self._log(f"POST {self.path} body[:260]={raw[:260]!r}")

        if self.path.startswith("/v1/chat/completions"):
            try:
                payload = json.loads(raw)
                msgs = payload.get("messages", [])
                sys_msg = msgs[0]["content"] if msgs else ""
                user_msg = msgs[1]["content"] if len(msgs) > 1 else ""
                self._log(f"  system[:100]={sys_msg[:100]!r}")
                self._log(f"  user[:220]={user_msg[:220]!r}")
            except Exception as e:
                self._log(f"  parse-error: {e}")
            resp = json.dumps({"choices": [{"message": {"content": json.dumps(GRADE)}}]}).encode()
            self._send(200, resp, "application/json")
        elif self.path.startswith("/api/docs/"):
            # Grist records API stand-in
            self._log("  Grist write accepted (row logged)")
            self._send(200, json.dumps({"id": 1}).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")


def serve(port):
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    print("verify_chain: 20128 (9Router) + 8484 (transcript/Grist) — Ctrl-C to stop", flush=True)
    threading.Thread(target=serve, args=(20128,), daemon=True).start()
    serve(8484)
