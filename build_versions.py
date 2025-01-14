import subprocess
import os
import shutil

def rename_and_move_file(command, bin_dir):

    start = command.find('--prefix "') + len('--prefix "')
    end = command.find('"', start)
    directory = command[start:end]
    command = command[start:end]

    print(directory)

    if directory is not None:
        # Change to the specified directory and then to the 'bin' subdirectory
        os.chdir(os.path.join(directory, 'bin'))

        # Check if the command contains 'win' or 'linux'
        if 'win' in command and os.path.exists('lambergar.exe'):
            # Rename 'lambergar.exe'
            os.rename('lambergar.exe', f'{command}.exe')
            if not os.path.exists(bin_dir):
                os.makedirs(bin_dir)            
            # Move the new file to the specified bin_dir
            shutil.move(f'{command}.exe', os.path.join(bin_dir, f'{command}.exe'))
        elif 'linux' in command and os.path.exists('lambergar'):
            # Rename 'lambergar'
            os.rename('lambergar', command)
            if not os.path.exists(bin_dir):
                os.makedirs(bin_dir)            
            # Move the new file to the specified bin_dir
            shutil.move(command, os.path.join(bin_dir, command))

        # Delete the 'bin' directory and the command directory
        os.chdir('..')  # Go up one directory
        shutil.rmtree('bin')  # Delete the 'bin' directory
        os.chdir('..')  # Go up one directory
        shutil.rmtree(directory)  # Delete the command directory

def extract_version(filename):
    with open(filename, 'r') as file:
        for line in file:
            if '"id name Lambergar ' in line:
                start = line.find('Lambergar ') + len('Lambergar ')
                end = line.find('"', start)
                version = line[start:end-2]
                return version
            
def build_ver(command, bin_dir):
    process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE)
    stdout, stderr = process.communicate()
    if process.returncode != 0:
        print(f"Error occurred: {stderr}")
    else:
        print(stdout)
    rename_and_move_file(command, bin_dir)

version = extract_version('./src/uci.zig')
print(f"Version: {version}")

bin_dir = f'..\\..\\binaries'

# Windows versions
command = f'zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast -Dcpu=x86_64 --prefix "lambergar-{version}-x86_64-win-VINTAGE"'
build_ver(command, bin_dir)

command = f'zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast -Dcpu=x86_64_v2 --prefix "lambergar-{version}-x86_64-win-POPCNT"'
build_ver(command, bin_dir)

command = f'zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast -Dcpu=x86_64_v3 --prefix "lambergar-{version}-x86_64-win-AVX2"'
build_ver(command, bin_dir)

#command = f'zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast -Dcpu=x86_64_v4 --prefix "lambergar-{version}-x86_64-win-AVX-512"'
#build_ver(command, bin_dir)

# Linux versions
command = f'zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Dcpu=x86_64 --prefix "lambergar-{version}-x86_64-linux-VINTAGE"'
build_ver(command, bin_dir)

command = f'zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Dcpu=x86_64_v2 --prefix "lambergar-{version}-x86_64-linux-POPCNT"'
build_ver(command, bin_dir)

command = f'zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Dcpu=x86_64_v3 --prefix "lambergar-{version}-x86_64-linux-AVX2"'
build_ver(command, bin_dir)

# Raspberry Pi version 
command = f'zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast --prefix "lambergar-{version}-aarch64-linux"'
build_ver(command, bin_dir)

#command = f'zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast -Dcpu=x86_64_v4 --prefix "lambergar-{version}-x86_64-linux-AVX-512"'
#build_ver(command, bin_dir)

"""
NO COMMENT ;)
"""