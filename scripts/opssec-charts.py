#!/usr/bin/env python3
# Requires: pip install matplotlib numpy

import argparse
import matplotlib.pyplot as plt
import numpy as np
import sys

# Updated to include 4 threads, excluding Totals
EXPECTED_LABELS = [
    "1 Thread Sets", "1 Thread Gets",
    "2 Threads Sets", "2 Threads Gets",
    "4 Threads Sets", "4 Threads Gets",
    "8 Threads Sets", "8 Threads Gets"
]

# Only Redis and Dragonfly
DBS = ["Redis", "Dragonfly"]


def normalize_threads(token):
    """
    Given "1 Thread", "1 Threads", "2 Thread", "4 Threads", "8 Threads", etc.,
    return exactly "1 Thread", "2 Threads", "4 Threads", or "8 Threads".
    """
    parts = token.split()
    if len(parts) != 2:
        return None
    num, word = parts
    if num == "1":
        return "1 Thread"
    elif num in ("2", "4", "8"):
        return f"{num} Threads"
    else:
        return None


def parse_db_and_threads(db_and_threads):
    """
    Parse database name and thread info from strings like:
    - "Redis 1 Thread"
    - "Redis TLS 1 Thread" 
    - "Dragonfly 2 Thread"
    
    Returns (db_name, thread_token) or (None, None) if parsing fails
    """
    tokens = db_and_threads.split()
    if len(tokens) < 3:
        return None, None
    
    # Handle TLS case: "Redis TLS 1 Thread" -> db="Redis", threads="1 Thread"
    if len(tokens) >= 4 and tokens[1] == "TLS":
        db = tokens[0]
        th_token = " ".join(tokens[2:4])  # "1 Thread"
        return db, th_token
    
    # Handle non-TLS case: "Redis 1 Thread" -> db="Redis", threads="1 Thread" 
    elif len(tokens) >= 3:
        db = tokens[0]
        th_token = " ".join(tokens[1:3])  # "1 Thread"
        return db, th_token
    
    return None, None


def parse_markdown_ops(filepath):
    """
    Read combined_all_results.md (or combined_all_results_tls.md). Return:
      data[db]["ops"][label] = float(ops/sec)
    Prints debug lines for every skipped row or stored value.
    """
    data = {
        db: {"ops": {lbl: 0.0 for lbl in EXPECTED_LABELS}}
        for db in DBS
    }

    print(f"[DEBUG] Opening file: {filepath}")
    with open(filepath, "r") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            # Skip markdown header separators and empty lines
            if not line or line.startswith("| ---") or "----" in line:
                continue

            if "|" not in line:
                print(f"  [DEBUG] Skipping: no '|' found -> {line}")
                continue

            parts = [p.strip() for p in line.split("|")]
            # Filter out empty parts
            parts = [p for p in parts if p]
            
            if len(parts) < 5:
                print(f"  [DEBUG] Skipping: fewer than 5 fields -> {parts}")
                continue

            db_and_threads = parts[0]
            op = parts[1]
            
            # Skip if this is a header row
            if op == "Type" or "Databases" in db_and_threads:
                continue
            
            # Skip Totals - we only plot Sets and Gets
            if op == "Totals":
                print(f"  [DEBUG] Skipping: Totals not plotted -> {line}")
                continue
                
            try:
                ops_val = parts[2]
            except IndexError:
                print(f"  [DEBUG] Skipping: missing Ops/sec column, parts = {parts}")
                continue

            # Skip rows with "---" values
            if ops_val == "---":
                print(f"  [DEBUG] Skipping: found '---' value in ops/sec column")
                continue

            db, th_token = parse_db_and_threads(db_and_threads)
            if db is None or th_token is None:
                print(f"  [DEBUG] SKIPPING: cannot parse db_and_threads '{db_and_threads}'")
                continue

            if db not in DBS:
                print(f"  [DEBUG] SKIPPING: Unknown DB '{db}'")
                continue

            th_norm = normalize_threads(th_token)
            if th_norm is None:
                print(f"  [DEBUG] SKIPPING: cannot normalize threads '{th_token}'")
                continue

            label = f"{th_norm} {op}"
            if label not in EXPECTED_LABELS:
                print(f"  [DEBUG] SKIPPING: label '{label}' not in EXPECTED_LABELS")
                continue

            try:
                opsf = float(ops_val)
            except ValueError as e:
                print(f"  [DEBUG] SKIPPING: cannot convert Ops/sec to float: '{ops_val}', error={e}")
                continue

            data[db]["ops"][label] = opsf
            print(f"  [DEBUG] Stored -> {db}.{label} = {opsf:.2f} ops/sec")

    print("[DEBUG] Finished parsing. Summary of ops/sec data:")
    for db in DBS:
        nonzero = {lbl: val for lbl, val in data[db]["ops"].items() if val != 0.0}
        print(f"  [DEBUG] DB = {db}: {len(nonzero)}/{len(EXPECTED_LABELS)} nonzero labels")
        if nonzero:
            for lbl, val in nonzero.items():
                print(f"    [DEBUG]   {lbl} -> {val:.2f}")

    return data


def plot_ops_chart(all_data, out_filename,
                     redis_io_threads, dragonfly_proactor_threads,
                     requests, clients, pipeline, data_size):
    """
    Build a grouped‐bar chart for Ops/sec across 2 DBs and 8 labels (Sets and Gets only, no Totals),
    and save to out_filename. Optimized for 8 data points with 2 databases.
    """
    vals = []
    for db in DBS:
        row = [all_data[db]["ops"].get(lbl, 0.0) for lbl in EXPECTED_LABELS]
        vals.append(row)
    arr = np.array(vals)  # shape = (2, 8)

    x = np.arange(len(EXPECTED_LABELS))
    width = 0.35  # Width for 2 bars
    offsets = [-0.5 * width, 0.5 * width]

    # Figure size optimized for 2 databases
    fig, ax = plt.subplots(figsize=(20, 12))

    DBS_WITH_THREADS = [
        f"Redis",
        f"Dragonfly"
    ]

    for i, db_label in enumerate(DBS_WITH_THREADS):
        ax.bar(
            x + offsets[i],
            arr[i],
            width,
            label=db_label
        )

    title_parts = [
        "Redis vs Dragonfly - Memtier Benchmarks",
        f"requests = {requests} clients = {clients} SET:GET = 1:15"
    ]
    ax.set_title(
        "\n".join(title_parts),
        fontsize=18,
        fontweight='bold',
        loc='center'
    )
    ax.set_ylabel("Ops/Sec", fontsize=14, fontweight='semibold')
    ax.grid(axis='y', linestyle='--', linewidth=0.5, alpha=0.7)
    ax.set_xticks(x)
    # Rotate x-axis labels for better readability with 8 labels
    ax.set_xticklabels(EXPECTED_LABELS, rotation=45, ha="right", fontsize=9)
    ax.legend(fontsize=12, loc='upper left')
    ax.tick_params(axis='y', labelsize=12)

    # Only add annotations for non-zero values
    for i, db in enumerate(DBS):
        for j, height in enumerate(arr[i]):
            if height > 0:  # Only annotate non-zero bars
                ax.annotate(
                    f"{int(round(height))}",
                    xy=(x[j] + offsets[i], height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha="center", va="bottom",
                    fontsize=8
                )

    plt.tight_layout(rect=[0, 0, 1, 0.94])
    print(f"[DEBUG] Saving Ops/Sec plot to {out_filename}")
    plt.savefig(out_filename, dpi=300, bbox_inches='tight')
    plt.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate Ops/sec charts from benchmark data.")
    parser.add_argument("md_path", help="Path to the markdown file with benchmark results (e.g., combined_all_results.md)")
    parser.add_argument("prefix", help="Prefix for output file names (e.g., nonTLS or TLS)")
    parser.add_argument("--redis_io_threads", default='2', help="Redis IO threads")
    parser.add_argument("--dragonfly_proactor_threads", default='3', help="Dragonfly proactor threads")
    parser.add_argument("--requests", default='200000', help="Number of requests")
    parser.add_argument("--clients", default='30', help="Number of clients")
    parser.add_argument("--pipeline", default='1', help="Pipeline depth")
    parser.add_argument("--data_size", default='1024', help="Data size in bytes")

    args = parser.parse_args()

    print(f"[DEBUG] Running opssec-charts.py on '{args.md_path}' with prefix '{args.prefix}'")
    data_ops = parse_markdown_ops(args.md_path)

    plot_ops_chart(
        data_ops,
        f"ops-{args.prefix}.png",
        args.redis_io_threads,
        args.dragonfly_proactor_threads,
        args.requests,
        args.clients,
        args.pipeline,
        args.data_size
    )