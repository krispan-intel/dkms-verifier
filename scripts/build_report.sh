#!/usr/bin/env bash
# Build releases/<tag>/report.html from summary.csv + analysis/.
# Targets are read from ../../targets.conf (same set used by run_release.sh).
set -euo pipefail

OUT=${1:?usage: build_report.sh <release-dir> <tag>}
TAG=${2:?tag}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONF="$ROOT/targets.conf"
SUM="$OUT/summary.csv"
HTML="$OUT/report.html"

[[ -f "$SUM" ]] || { echo "ERROR: $SUM missing" >&2; exit 2; }

# Read target ids + descriptions from config.
mapfile -t TARGETS < <(grep -vE '^[[:space:]]*(#|$)' "$CONF" | awk '{print $1}')
declare -A TGT_DESC TGT_VER
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$line" ]] && continue
  id=$(echo "$line" | awk '{print $1}')
  ver=$(echo "$line" | awk '{print $2}')
  desc=$(echo "$line" | awk '{$1=$2=""; sub(/^[ \t]+/,""); print}')
  TGT_VER[$id]=$ver
  TGT_DESC[$id]=$desc
done < "$CONF"

mods=$(awk -F, 'NR>1 {print $1}' "$SUM" | sort -u)
n_mods=$(echo "$mods" | wc -l)

verdict_for() {
  local real=$1
  if   [[ "$real" -eq 0 ]];  then printf '<span class="pill pass">DKMS OK</span>'
  elif [[ "$real" -le 5 ]];  then printf '<span class="pill warn">DKMS with shims</span>'
  elif [[ "$real" -le 30 ]]; then printf '<span class="pill fail">High risk</span>'
  else                           printf '<span class="pill fail">Very high risk</span>'
  fi
}

# Aggregate per-target.
declare -A AGG_OK AGG_SHIM AGG_HIGH
for tgt in "${TARGETS[@]}"; do
  AGG_OK[$tgt]=0; AGG_SHIM[$tgt]=0; AGG_HIGH[$tgt]=0
done
for m in $mods; do
  for tgt in "${TARGETS[@]}"; do
    real=$(awk -F, -v m="$m" -v t="$tgt" '$1==m && $2==t {print $5}' "$SUM")
    [[ -z "$real" ]] && continue
    if   [[ "$real" -eq 0 ]]; then AGG_OK[$tgt]=$((AGG_OK[$tgt]+1))
    elif [[ "$real" -le 5 ]]; then AGG_SHIM[$tgt]=$((AGG_SHIM[$tgt]+1))
    else                          AGG_HIGH[$tgt]=$((AGG_HIGH[$tgt]+1))
    fi
  done
done

# Header + TL;DR.
{
  cat <<HTML_HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OOT DKMS feasibility — ${TAG}</title>
<style>
  body  { font: 14px/1.55 system-ui, sans-serif; max-width: 1180px; margin: 2rem auto; padding: 0 1rem; color: #222; }
  h1, h2, h3 { color: #1a1a1a; }
  h1 { border-bottom: 2px solid #2c5aa0; padding-bottom: .3rem; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { border: 1px solid #ddd; padding: .4rem .6rem; text-align: left; vertical-align: top; }
  th { background: #f4f6f8; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  .pill { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 12px; font-weight: 600; }
  .pass { background: #d4edda; color: #155724; }
  .warn { background: #fff3cd; color: #856404; }
  .fail { background: #f8d7da; color: #721c24; }
  .nope { background: #d1ecf1; color: #0c5460; }
  code { background: #f4f4f4; padding: 1px 4px; border-radius: 3px; font-size: 13px; }
  details { margin: .3rem 0; }
  summary { cursor: pointer; }
  .small  { font-size: 13px; color: #555; }
  .barbox { display: inline-block; width: 200px; background: #eee; border-radius: 3px; overflow: hidden; vertical-align: middle; height: 12px; }
  .bar    { display: inline-block; height: 12px; background: #d9534f; vertical-align: top; }
  .bar.ok { background: #5cb85c; }
  ul.syms { columns: 2; column-gap: 1.5rem; font-family: ui-monospace, Menlo, monospace; font-size: 12px; }
  ul.syms li { break-inside: avoid; }
  .tldr { background: #f7faff; border: 1px solid #c7d8f0; border-radius: 6px; padding: .8rem 1rem; margin: 1rem 0; }
  .tldr h2 { margin-top: 0; }
  .tldr-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1rem; }
  .tldr-card { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: .6rem .8rem; }
  .tldr-card h3 { margin: 0 0 .3rem 0; font-size: 14px; }
  .tldr-card .big { font-size: 22px; font-weight: 600; color: #1a1a1a; }
</style>
</head>
<body>

<h1>OOT DKMS feasibility — <code>${TAG}</code></h1>
<p class="small">
HTML_HEAD

  if [[ -f "$OUT/manifest.txt" ]]; then
    grep -E '^(base|head|generated_at|n_modules|n_modules_checked)=' "$OUT/manifest.txt" \
      | sed 's/=/: /; s/^/  /' | tr '\n' '|' | sed 's/|/ &middot; /g; s/&middot; $//; s/&middot; / · /g'
  fi

  cat <<HTML_TLDR
</p>

<div class="tldr">
<h2>TL;DR — ${n_mods} modules touched by this release</h2>
<div class="tldr-grid">
HTML_TLDR

  for tgt in "${TARGETS[@]}"; do
    desc="${TGT_DESC[$tgt]:-$tgt}"
    cat <<HTML_CARD
  <div class="tldr-card">
    <h3>${desc} <span class="small">(<code>${TGT_VER[$tgt]:-?}</code>)</span></h3>
    <p>
      <span class="big">${AGG_OK[$tgt]}</span> <span class="pill pass">DKMS OK</span> &nbsp;
      <span class="big">${AGG_SHIM[$tgt]}</span> <span class="pill warn">with shims</span> &nbsp;
      <span class="big">${AGG_HIGH[$tgt]}</span> <span class="pill fail">high risk</span>
    </p>
  </div>
HTML_CARD
  done

  cat <<'HTML_TBL'
</div>
</div>

<h2>Per-module verdicts</h2>
<table>
<tr>
  <th>Module</th>
HTML_TBL

  for tgt in "${TARGETS[@]}"; do
    desc="${TGT_DESC[$tgt]:-$tgt}"
    echo "  <th>${desc}<br><span class=\"small\">CRC / real-missing</span></th>"
  done
  for tgt in "${TARGETS[@]}"; do
    echo "  <th>DKMS @ ${TGT_VER[$tgt]:-$tgt}</th>"
  done
  echo "</tr>"

  for m in $mods; do
    echo "<tr>"
    echo "  <td><a href=\"#mod-${m}\"><code>${m}</code></a></td>"
    for tgt in "${TARGETS[@]}"; do
      total=$(awk -F, -v m="$m" -v t="$tgt" '$1==m && $2==t {print $3}' "$SUM")
      crc=$(awk   -F, -v m="$m" -v t="$tgt" '$1==m && $2==t {print $6}' "$SUM")
      real=$(awk  -F, -v m="$m" -v t="$tgt" '$1==m && $2==t {print $5}' "$SUM")
      pct=$((real * 100 / (total>0?total:1))); ((pct>100)) && pct=100
      cat <<HTML
  <td>
    CRC <span class="pill warn">${crc}</span>
    real-missing <span class="pill fail">${real}</span> / ${total}
    <div><span class="barbox"><span class="bar" style="width:${pct}%"></span></span></div>
  </td>
HTML
    done
    for tgt in "${TARGETS[@]}"; do
      real=$(awk  -F, -v m="$m" -v t="$tgt" '$1==m && $2==t {print $5}' "$SUM")
      echo "  <td>$(verdict_for "$real")</td>"
    done
    echo "</tr>"
  done
  echo "</table>"

  cat <<'HTML_LEGEND'

<h3>Legend</h3>
<p>
<span class="pill pass">DKMS OK</span> rebuild loads cleanly &nbsp;
<span class="pill warn">DKMS with shims</span> ≤ 5 APIs need backport &nbsp;
<span class="pill fail">High risk</span> 6–30 APIs missing &nbsp;
<span class="pill fail">Very high risk</span> > 30 APIs missing
</p>

<hr>

<h2>Method &amp; definitions</h2>
<p>
For each module, run <code>modprobe --dump-modversions</code> on the prebuilt
<code>.ko</code> and compare the <code>(symbol, CRC)</code> table against
the target Ubuntu kernel's <code>Module.symvers</code>.
</p>
<ul>
  <li><b>CRC mismatch</b> = symbol exists but CRC differs. <em>Recoverable
      by DKMS rebuild.</em></li>
  <li><b>Real-missing</b> = symbol absent on target, after filtering
      kernel-internal renames (<code>*_noprof</code>,
      <code>__ref_stack_chk_guard</code>, etc.). <strong>This is the real
      DKMS blocker count.</strong></li>
</ul>

<h2>Per-module missing-API detail</h2>
HTML_LEGEND

  for m in $mods; do
    echo "<h3 id=\"mod-${m}\"><code>${m}</code></h3>"
    for tgt in "${TARGETS[@]}"; do
      desc="${TGT_DESC[$tgt]:-$tgt}"
      f="$OUT/analysis/${m}-vs-${tgt}-real-missing.txt"
      count=0
      [[ -s "$f" ]] && count=$(wc -l <"$f")
      echo "<details>"
      echo "<summary>vs <b>${desc}</b> &mdash; ${count} APIs missing</summary>"
      if [[ "$count" -eq 0 ]]; then
        echo '<p class="small">No real-missing APIs &mdash; DKMS rebuild is sufficient.</p>'
      else
        echo '<ul class="syms">'
        while IFS= read -r sym; do
          [[ -n "$sym" ]] && echo "<li>${sym}</li>"
        done < "$f"
        echo '</ul>'
      fi
      echo "</details>"
    done
  done

  cat <<'HTML_FOOT'

<h2>Source files</h2>
<ul>
  <li><code>summary.csv</code> &mdash; raw numbers driving this page.</li>
  <li><code>modules.txt</code> &mdash; modules discovered from the diff.</li>
  <li><code>manifest.txt</code> &mdash; tag, base, head, generation timestamp.</li>
  <li><code>raw/&lt;mod&gt;-vs-&lt;target&gt;/</code> &mdash; per-run missing /
      crc_mismatch detail.</li>
  <li><code>analysis/&lt;mod&gt;-vs-&lt;target&gt;-real-missing.txt</code>
      &mdash; filtered API-removal lists.</li>
</ul>

</body></html>
HTML_FOOT

} > "$HTML"

echo "wrote $HTML"
