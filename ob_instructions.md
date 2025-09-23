
# OpenBench instructions for me

## Installing Make on Windows

### Method: Install Chocolatey First (Then Install Make)

#### Step 1: Install Chocolatey (package manager)
Open PowerShell as Administrator and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

#### Step 2: Install Make using Chocolatey

##### PowerShell Commands
```powershell
choco install make
Import-Module $env:ChocolateyInstall\helpers\chocolateyProfile.psm1
refreshenv
```

##### CMD Commands
```cmd
C:\ProgramData\chocolatey\bin\make --version
set PATH=%PATH%;C:\ProgramData\chocolatey\bin
make --version
```

## OpenBench server setup

```cmd
netsh advfirewall firewall add rule name="OpenBench" dir=in action=allow protocol=TCP localport=8000
```

## Install Zig

```cmd
set PATH=%PATH%;c:\Users\janezp\AppData\Roaming\Code\User\globalStorage\ziglang.vscode-zig\zig\x86_64-windows-0.15.1\
```

## Run OpenBench in WSL

```bash
(base) janezp@lr-force:~$ conda activate py-ob
(py-ob) janezp@lr-force:~$ cd OpenBench/
(py-ob) janezp@lr-force:~/OpenBench$ python3 manage.py runserver 0.0.0.0:8000
```

## Run client

python3.12 client.py -U lamb -P lamb -S http://192.168.65.97:8000 -T 9 -N 1 -I force