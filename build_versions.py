import argparse
import os
import shutil
import subprocess


def rename_and_move_file(prefix_name, bin_dir):
    directory = prefix_name

    print(prefix_name)

    if directory is not None:
        os.chdir(os.path.join(directory, "bin"))

        if "win" in prefix_name and os.path.exists("lambergar.exe"):
            os.rename("lambergar.exe", f"{prefix_name}.exe")
            if not os.path.exists(bin_dir):
                os.makedirs(bin_dir)
            shutil.move(f"{prefix_name}.exe", os.path.join(bin_dir, f"{prefix_name}.exe"))
        elif ("linux" in prefix_name or "macos" in prefix_name) and os.path.exists("lambergar"):
            os.rename("lambergar", prefix_name)
            if not os.path.exists(bin_dir):
                os.makedirs(bin_dir)
            shutil.move(prefix_name, os.path.join(bin_dir, prefix_name))

        os.chdir("..")
        shutil.rmtree("bin")
        os.chdir("..")
        shutil.rmtree(directory)


def extract_version(filename):
    with open(filename, "r") as file:
        for line in file:
            if '"id name Lambergar ' in line:
                start = line.find("Lambergar ") + len("Lambergar ")
                end = line.find('"', start)
                version = line[start:end - 2]
                return version
    raise RuntimeError(f"Could not extract version from {filename}")


def build_ver(command, prefix_name, bin_dir):
    process = subprocess.run(command, capture_output=True, text=True)
    if process.stdout:
        print(process.stdout)
    if process.returncode != 0:
        if process.stderr:
            print(process.stderr)
        raise SystemExit(process.returncode)
    rename_and_move_file(prefix_name, bin_dir)


def build_command(zig, target, cpu, prefix_name):
    return [
        zig,
        "build",
        f"-Dtarget={target}",
        "--release=fast",
        f"-Dcpu={cpu}",
        "--prefix",
        prefix_name,
    ]


def parse_args():
    parser = argparse.ArgumentParser(description="Build release binaries with a chosen Zig executable.")
    parser.add_argument(
        "--zig",
        default="zig",
        help="Path to the Zig executable to use, for example zig or C:\\path\\to\\zig.exe",
    )
    parser.add_argument(
        "--bin-dir",
        default="..\\..\\binaries",
        help="Output directory for renamed binaries",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    version = extract_version("./src/uci.zig")
    print(f"Version: {version}")
    print(f"Zig: {args.zig}")

    bin_dir = args.bin_dir

    print("Skipping Windows VINTAGE/POPCNT: NNUE AVX2 inline asm requires x86_64_v3+")

    prefix_name = f"lambergar-{version}-x86_64-win-AVX2"
    build_ver(build_command(args.zig, "x86_64-windows", "x86_64_v3", prefix_name), prefix_name, bin_dir)

    prefix_name = f"lambergar-{version}-x86_64-win-AVX-512"
    build_ver(build_command(args.zig, "x86_64-windows", "x86_64_v4", prefix_name), prefix_name, bin_dir)

    print("Skipping Linux VINTAGE/POPCNT: NNUE AVX2 inline asm requires x86_64_v3+")

    prefix_name = f"lambergar-{version}-x86_64-linux-AVX2"
    build_ver(build_command(args.zig, "x86_64-linux", "x86_64_v3", prefix_name), prefix_name, bin_dir)

    print("Skipping aarch64 Linux: NNUE AVX2 inline asm is x86_64-only")

    print("Skipping macOS x86_64 VINTAGE/POPCNT: NNUE AVX2 inline asm requires x86_64_v3+")

    prefix_name = f"lambergar-{version}-x86_64-macos-AVX2"
    build_ver(build_command(args.zig, "x86_64-macos", "x86_64_v3", prefix_name), prefix_name, bin_dir)

    print("Skipping aarch64 macOS: NNUE AVX2 inline asm is x86_64-only")


if __name__ == "__main__":
    main()
