#!/usr/bin/env python3
"""Extract a Helm chart .tgz from a sh.helm.release.v1.* secret value."""
import sys, base64, gzip, json, tarfile, io, os

if len(sys.argv) != 3:
    print("usage: extract_helm_chart.py <secret-data-base64> <output-dir>", file=sys.stderr)
    sys.exit(1)

b64 = sys.argv[1]
out = sys.argv[2]

# Helm secret data is base64-of-base64-of-gzipped-json
once = base64.b64decode(b64)
twice = base64.b64decode(once)
release_json = gzip.decompress(twice).decode("utf-8")
release = json.loads(release_json)

chart = release.get("chart") or {}
md = chart.get("metadata") or {}
print(f"chart name   : {md.get('name')}")
print(f"chart version: {md.get('version')}")
print(f"chart appVer : {md.get('appVersion')}")
print(f"templates    : {len(chart.get('templates') or [])}")
print(f"files        : {len(chart.get('files') or [])}")
print(f"deps         : {len(chart.get('dependencies') or [])}")
print(f"values keys  : {list((chart.get('values') or {}).keys())[:10]}")

os.makedirs(out, exist_ok=True)

def write_files(c, base):
    """Write chart + each dependency as a separate directory tree under out/."""
    md = c.get("metadata") or {}
    name = md.get("name", "chart")
    cdir = os.path.join(base, name)
    os.makedirs(cdir, exist_ok=True)
    os.makedirs(os.path.join(cdir, "templates"), exist_ok=True)
    # Chart.yaml
    with open(os.path.join(cdir, "Chart.yaml"), "w") as f:
        import yaml
        yaml.safe_dump(md, f)
    # values.yaml
    with open(os.path.join(cdir, "values.yaml"), "w") as f:
        import yaml
        yaml.safe_dump(c.get("values") or {}, f)
    # templates
    for t in (c.get("templates") or []):
        tname = t.get("name")
        tdata = t.get("data")  # base64
        if tname and tdata:
            tpath = os.path.join(cdir, tname)
            os.makedirs(os.path.dirname(tpath), exist_ok=True)
            with open(tpath, "wb") as f:
                f.write(base64.b64decode(tdata))
    # extra files
    for t in (c.get("files") or []):
        tname = t.get("name")
        tdata = t.get("data")
        if tname and tdata:
            tpath = os.path.join(cdir, tname)
            os.makedirs(os.path.dirname(tpath), exist_ok=True)
            with open(tpath, "wb") as f:
                f.write(base64.b64decode(tdata))
    # recurse dependencies under charts/
    deps_dir = os.path.join(cdir, "charts")
    for dep in (c.get("dependencies") or []):
        os.makedirs(deps_dir, exist_ok=True)
        write_files(dep, deps_dir)
    return cdir

cdir = write_files(chart, out)
print(f"wrote chart tree to: {cdir}")
