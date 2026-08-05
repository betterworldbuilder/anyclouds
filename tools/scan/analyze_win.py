import winrm
import sys

def run_ps(session, script):
    res = session.run_ps(script)
    if res.status_code == 0:
        return res.std_out.decode('utf-8').strip()
    return f"ERROR:\n{res.std_err.decode('utf-8')}"

def analyze(ip, user, password, desc):
    print(f"\n==========================================")
    print(f"ANALYZING {desc} ({ip})")
    print(f"==========================================")
    try:
        session = winrm.Session(ip, auth=(user, password), transport='ntlm', server_cert_validation='ignore')
        
        # 1. Check Service Status
        services = ['viostor', 'vioscsi', 'netkvm', 'vioserial', 'balloon', 'xenvbd', 'xennet']
        print("\n--- Service States (Start Type) ---")
        script = ""
        for s in services:
            script += f"Get-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\{s}' -Name Start -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Start; "
        
        res = session.run_ps(script)
        lines = res.std_out.decode('utf-8').strip().split('\n')
        for i, s in enumerate(services):
            val = lines[i].strip() if i < len(lines) and lines[i].strip() else "NOT FOUND"
            print(f"{s.ljust(15)}: Start={val}")

        # 2. Check CriticalDeviceDatabase
        print("\n--- CriticalDeviceDatabase (VirtIO PCI) ---")
        script = r"""
        $paths = @(
            'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001',
            'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042',
            'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004',
            'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048'
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                $svc = Get-ItemProperty -Path $p -Name Service -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Service
                Write-Output "$p -> Service=$svc"
            } else {
                Write-Output "$p -> NOT FOUND"
            }
        }
        """
        print(run_ps(session, script))
        
    except Exception as e:
        print(f"Failed to connect to {ip}: {e}")

if __name__ == '__main__':
    analyze('104.130.26.194', 'Administrator', 'cGqtX7uAkD9R9xx3SRJTZoBU', 'OSPC Windows 2016')
    analyze('146.20.61.130', 'Administrator', 'Inzemood@67', 'FLEX Windows 2016')
