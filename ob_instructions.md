
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

## Install Zig

