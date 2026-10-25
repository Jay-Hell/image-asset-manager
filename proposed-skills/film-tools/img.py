"""Art generation for the film through Image Asset Manager (`iam generate`): the app holds the keys, files each
image to the project "Ionic Test" with its prompt, model and cost, and opens itself if it is closed.
Usage: python3 img.py ../art/gen/prompts.json [ids,...]  -> art/gen/<id>.png ; prompts.json: {id: {prompt, aspect}}
Needs `iam` on the PATH (cd image-asset-manager/mcp-server && npm link). No OpenRouter key and no OR_KEY_FILE.

(Smaller alternative, kept in the old go(): generate through OpenRouter as before, then
 subprocess.run(["iam","import",path,"--project","Ionic Test","--prompt",prompt,"--provider","openrouter",
 "--model",MODEL,"--cost-usd",str(cost),"--tag","film"]). That still needs the key file.)"""
import json, sys, os, shutil, subprocess, tempfile, concurrent.futures as cf
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, "..", "art", "gen")
SUFFIX = (" Editorial print collage, real paper texture with visible fibres, crisp knife-cut or torn edge, halftone print detail, "
          "muted off-white and charcoal ink with a single orange or teal accent at most, soft overhead light, photographed flat from directly above, "
          "restrained, no faces, no logos, no text.")
KEYBG = (" The object is isolated on a perfectly flat, uniform, pure magenta (#FF00FF) background with no shadow, no gradient and no other objects, "
         "so it can be cut out cleanly. The object itself contains no magenta or pink.")
PROJECT = os.environ.get("IMG_PROJECT", "Ionic Test")
P = json.load(open(sys.argv[1])); ids = sys.argv[2].split(",") if len(sys.argv) > 2 else list(P)
MODEL = os.environ.get("IMG_MODEL", "google/gemini-2.5-flash-image")
if ":" not in MODEL.split("/")[0]: MODEL = "openrouter:" + MODEL  # iam wants provider:model
def go(i):
    p = P[i]; prompt = p["prompt"] + (KEYBG if p.get("key", True) else "") + SUFFIX
    tmp = tempfile.mkdtemp(prefix="img-")
    try:
        r = subprocess.run(["iam", "generate", "--prompt", prompt, "--model", MODEL, "--aspect", p.get("aspect", "1:1"),
                            "--project", PROJECT, "--tag", "film", "--out", tmp], capture_output=True, text=True, timeout=600)
        if r.returncode != 0: return i, 0, "FAILED: " + (r.stderr.strip()[:300] or r.stdout.strip()[:300])
        j = json.loads(r.stdout.strip().splitlines()[0])
        got = j.get("generated") or []
        if not got or not got[0].get("copied_to"): return i, 0, "NO IMAGE"
        src = got[0]["copied_to"]; ext = os.path.splitext(src)[1] or ".png"
        shutil.copyfile(src, os.path.join(OUT, f"{i}{ext}"))
        cost = (j.get("cost") or {}).get("actual_gbp") or 0
        return i, cost, "ok" + ("" if ext == ".png" else f" (saved as {ext}, not .png)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
tot = 0
with cf.ThreadPoolExecutor(4) as ex:
    for i, c, s in ex.map(go, ids): tot += c; print(i, round(c, 4), s, flush=True)
print("COST GBP", round(tot, 4))
