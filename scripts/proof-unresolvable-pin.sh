#!/usr/bin/env bash
# proof-unresolvable-pin.sh — execute the CHANGED branches of pr-validator.yml LIVE against
# the real GitHub endpoints, in the unresolvable-pin state (opencharly/charly#723).
#
# Why not a workflow dispatch: the only live way to drive the unresolvable-pin path is a pin
# whose release does not exist, and a dispatch would post an INCONCLUSIVE comment and a RED
# required check on whatever PR it targets — polluting a real PR. This harness runs the SAME
# shell the workflow runs, with the same inputs, against the same live endpoints, and prints
# each branch's real output.
#
# usage: bash proof-unresolvable-pin.sh <tag-with-no-release>
set -euo pipefail
TAG="${1:?usage: proof-unresolvable-pin.sh <tag-with-no-release>}"
WF="${WF:-.github/workflows/pr-validator.yml}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"; export GH_TOKEN

python3 - "$WF" "$TAG" "$TMP" <<'PY'
import subprocess, os, re, sys
wf, TAG, TMP = sys.argv[1], sys.argv[2], sys.argv[3]
lines=open(wf).read().split('\n')
def step_body(anchor):
    for i,l in enumerate(lines):
        if anchor in l:
            for j in range(i, min(i+60, len(lines))):
                if lines[j].lstrip().startswith('run: |'):
                    ind=len(lines[j])-len(lines[j].lstrip()); body=[]; k=j+1
                    while k < len(lines):
                        n=lines[k]
                        if n.strip()=='' : body.append(''); k+=1; continue
                        if (len(n)-len(n.lstrip())) > ind: body.append(n); k+=1
                        else: break
                    base=min(len(b)-len(b.lstrip()) for b in body if b.strip())
                    return "\n".join(b[base:] if b.strip() else '' for b in body)
    raise SystemExit('no run block for '+anchor)

env=dict(os.environ, CHARLY_VERSION=TAG, PIN_FROM='inputs.charly-version', RUNNER_TEMP=TMP)

print("=== [1] ensure-charly (CHANGED), live, pin=%s — a tag whose release does not exist" % TAG)
o1=f'{TMP}/o1'; open(o1,'w').close()
r=subprocess.run(['bash','-c',step_body('"Ensure charly').replace('${{ runner.temp }}', TMP)],
                 env=dict(env, GITHUB_OUTPUT=o1), capture_output=True, text=True)
print("$ CHARLY_VERSION=%s PIN_FROM=inputs.charly-version bash <the changed step>" % TAG)
print((r.stdout+r.stderr).strip().replace(TMP,'$RUNNER_TEMP'))
print("exit=%d" % r.returncode); print("GITHUB_OUTPUT:"); print(open(o1).read().strip())
vals=dict(l.split('=',1) for l in open(o1).read().splitlines() if '=' in l)

print("=== [2] parse step (CHANGED branch), live, with those outputs")
pb=step_body('Parse verdict'); m=re.search(r'(# UNRESOLVABLE PIN FIRST.*?\n(?:.*\n)*? *fi\n)', pb)
o2=f'{TMP}/o2'; open(o2,'w').close()
r2=subprocess.run(['bash','-c',m.group(1)],
                  env=dict(env, GITHUB_OUTPUT=o2,
                           ENGINE_UNRESOLVED=vals.get('engine_unresolved',''),
                           PIN_TAG=vals.get('pin_tag',''), PIN_FROM=vals.get('pin_from',''),
                           PIN_CLASS=vals.get('pin_class','')), capture_output=True, text=True)
print((r2.stdout+r2.stderr).strip()); print("exit=%d" % r2.returncode); print(open(o2).read().strip())

print("=== [3] Gate (inconclusive) (CHANGED branch), live — the comment body it would post")
cb=step_body('Gate (inconclusive)')
b3=re.search(r'(if \[ "\$\{ENGINE_UNRESOLVED:-}" = "true" \]; then\n(?:.*\n)*? *fi\n)', cb)
lab=re.search(r'(verdict_class_label="eval.*?\n(?:.*\n)*? *fi\n)', cb)
script=("ENGINE_UNRESOLVED=true\nPIN_TAG=%s\nPIN_FROM=inputs.charly-version\nPIN_CLASS='%s'\n"
        "INCONCLUSIVE_INFRA=true\n%s\n%s\n"
        "echo '- class: '\"$class\"\necho '- Verdict class: '\"$verdict_class_label\"\n"
        "echo \"$rootcause\"\necho \"$remedy1\"\necho \"$remedy2\"\n") % (
        TAG, vals.get('pin_class',''), b3.group(1), lab.group(1))
open(f'{TMP}/c.sh','w').write(script)
r3=subprocess.run(['bash',f'{TMP}/c.sh'], capture_output=True, text=True)
print((r3.stdout+r3.stderr).strip()); print("exit=%d" % r3.returncode)
PY
