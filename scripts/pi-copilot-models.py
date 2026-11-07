#!/usr/bin/env python3
"""Generate ~/.pi/agent/models.json from the models the logged-in Copilot account really has.

pi 0.73.0 ships a hard-coded GitHub Copilot model list (Claude 4.x, GPT-5.x ...)
that does not match what the account offers (claude-sonnet-5.5, claude-opus-5.5,
gpt-5.6/6.x ...), so most built-in entries answer `model_not_supported`. Run this
after `pi` login (and whenever the account's catalog changes) on the machine
that runs pi; pi merges the entries into its built-in github-copilot provider and
keeps using the existing OAuth login. Reads ~/.pi/agent/auth.json; prints no secrets.
Verify with: pi --list-models; pi -p --model github-copilot/<id> hi
"""
import json,urllib.request,re,os
a=json.load(open("/home/spencer/.pi/agent/auth.json"))["github-copilot"]
base="https://"+re.search(r"proxy-ep=([^;]+)",a["access"]).group(1).replace("proxy.","api.")
HDR={"User-Agent":"GitHubCopilotChat/0.35.0","Editor-Version":"vscode/1.107.0","Editor-Plugin-Version":"copilot-chat/0.35.0","Copilot-Integration-Id":"vscode-chat"}
d=json.load(urllib.request.urlopen(urllib.request.Request(base+"/models",headers=dict(HDR,Authorization="Bearer "+a["access"])),timeout=40))
models=[]
for m in sorted(d["data"],key=lambda m:m["id"]):
    if not m.get("model_picker_enabled") or m.get("policy",{}).get("state")!="enabled": continue
    ep=m.get("supported_endpoints",[])
    cap=m.get("capabilities",{}); lim=cap.get("limits",{}); sup=cap.get("supports",{})
    e={"id":m["id"],"name":m.get("name",m["id"])}
    if "/v1/messages" in ep:
        e["api"]="anthropic-messages"; e["compat"]={"supportsEagerToolInputStreaming":False}
    elif "/responses" in ep:
        e["api"]="openai-responses"
    elif "/chat/completions" in ep:
        e["api"]="openai-completions"; e["compat"]={"supportsStore":False,"supportsDeveloperRole":False,"supportsReasoningEffort":False}
    else: continue
    e["reasoning"]=bool(sup.get("adaptive_thinking") or sup.get("reasoning_effort") or sup.get("max_thinking_budget"))
    # pi 0.73 sends `thinking.type=enabled` to every Claude model it does not
    # hard-code as adaptive (4.6/4.7 only); the 5.x models reject that. Without
    # the thinking parameter they work, so mark them non-reasoning.
    if e["api"]=="anthropic-messages" and not re.search(r"(opus|sonnet)-4[.-][67]",m["id"]) and not m["id"].startswith("claude-haiku-4"):
        e["reasoning"]=False
    e["input"]=["text","image"] if sup.get("vision") else ["text"]
    cw=lim.get("max_context_window_tokens"); mo=lim.get("max_output_tokens")
    if cw: e["contextWindow"]=cw
    if mo: e["maxTokens"]=mo
    models.append(e)
out={"providers":{"github-copilot":{"headers":HDR,"models":models}}}
os.makedirs("/home/spencer/.pi/agent",exist_ok=True)
json.dump(out,open("/home/spencer/.pi/agent/models.json","w"),indent=2)
print(len(models),"models:",", ".join(m["id"] for m in models))
