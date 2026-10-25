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
FAMILY = os.environ.get("IMG_FAMILY", "Ionic Test films")  # the film's name: its images are one variant family
def go(i):
    p = P[i]; prompt = p["prompt"] + (KEYBG if p.get("key", True) else "") + SUFFIX
    tmp = tempfile.mkdtemp(prefix="img-")
    try:
        r = subprocess.run(["iam", "generate", "--prompt", prompt, "--model", MODEL, "--aspect", p.get("aspect", "1:1"),
                            "--project", PROJECT, "--family", FAMILY, "--tag", "film", "--out", tmp],
                           capture_output=True, text=True, timeout=600)
        # iam prints its JSON before it exits 1 over a failed copy, so read it whatever the exit code was:
        # an image that was made, filed and charged must never come back as "no image, cost 0".
        j = {}
        try: j = json.loads(r.stdout.strip().splitlines()[0])
        except (ValueError, IndexError): pass
        got = (j.get("generated") or [{}])[0] if isinstance(j, dict) else {}
        cost = ((j.get("cost") or {}).get("actual_gbp") or 0) if isinstance(j, dict) else 0
        aid = got.get("asset_id")
        if not aid:
            return i, 0, "FAILED: " + (r.stderr.strip()[:300] or r.stdout.strip()[:300] or "NO IMAGE")
        tag = f"asset {aid}" + ("" if r.returncode == 0 else f" (iam: {r.stderr.strip()[:200]})")
        src = got.get("copied_to") or got.get("file_path")  # the library file is the fallback; it is only read
        if not src or not os.path.isfile(src):
            return i, cost, f"FAILED to save, but {tag} is in the library, cost charged"
        dest = os.path.join(OUT, f"{i}.png")  # the file contract: always <id>.png, whatever the app stored
        try:
            if os.path.splitext(src)[1].lower() == ".png": shutil.copyfile(src, dest)
            else:
                c = subprocess.run(["sips", "-s", "format", "png", src, "--out", dest], capture_output=True, text=True, timeout=120)
                if c.returncode != 0 or not os.path.isfile(dest): raise OSError("sips failed: " + (c.stderr.strip()[:200] or c.stdout.strip()[:200]))
        except OSError as e:
            return i, cost, f"FAILED to save ({e}), but {tag} is in the library, cost charged"
        return i, cost, "ok " + tag if r.returncode == 0 else "saved, but " + tag
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
tot = 0
with cf.ThreadPoolExecutor(4) as ex:
    for i, c, s in ex.map(go, ids): tot += c; print(i, round(c, 4), s, flush=True)
print("COST GBP", round(tot, 4))
