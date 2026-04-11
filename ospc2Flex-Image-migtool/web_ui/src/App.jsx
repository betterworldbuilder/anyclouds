import React, { useState, useEffect, useRef } from 'react';
import './index.css';

function App() {
  const [formData, setFormData] = useState({
    ospc_openrc: '~/ospc-openrc.sh',
    flex_openrc: '~/flex-openrc.sh',
    server_name: '',
    snapshot_name: '',
    target_format: 'qcow2',
    visibility: 'private',
    dry_run: true,
    cleanup_snapshot: false,
    
    boot_test_vm: false,
    test_server_name: '',
    flex_flavor: '',
    flex_network_id: '',
    flex_key_name: '',
    floating_ip: '',
    
    repair_guest: false,
    ssh_key_path: '',
    ssh_user: 'ubuntu',
    new_hostname: '',
    flex_net_iface: '',
    systemd_services: '',
    app_endpoint_map_file: '',
    fix_fstab: false,
    fix_netplan: false,
    clean_hosts_file: false,
    skip_cloud_init_clean: false,
    skip_qemu_guest_agent: false
  });

  const [logs, setLogs] = useState([]);
  const [isExecuting, setIsExecuting] = useState(false);
  const consoleRef = useRef(null);

  useEffect(() => {
    if (consoleRef.current) {
      consoleRef.current.scrollTop = consoleRef.current.scrollHeight;
    }
  }, [logs]);

  // Handle Form changes
  const handleChange = (e) => {
    const { name, value, type, checked } = e.target;
    setFormData(prev => {
      const newData = { ...prev, [name]: type === 'checkbox' ? checked : value };
      
      // Auto-check boot test if guest repair is on
      if (name === 'repair_guest' && checked && !prev.boot_test_vm) {
        newData.boot_test_vm = true;
      }
      return newData;
    });
  };

  const appendLog = (text, type = 'info') => {
    setLogs(prev => [...prev, { text, type }]);
  };

  const clearLogs = () => {
    setLogs([{ text: 'Console cleared.', type: 'system' }]);
  };

  const colorizeLogLine = (text) => {
    if (text.includes('--- EXECUTING ---')) return 'command';
    if (text.includes('[OK]') || text.includes('[DONE]')) return 'success';
    if (text.includes('ERROR]') || text.includes('failed') || text.includes('Exception:')) return 'error';
    return 'info';
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    setIsExecuting(true);
    appendLog('\n============= NEW MIGRATION RUN =============', 'system');

    try {
      const response = await fetch('/api/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(formData)
      });

      if (!response.body) throw new Error('ReadableStream not supported.');

      const reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let buffer = '';

      while (true) {
        const { value, done } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        
        let boundaryPosition = buffer.indexOf('\n\n');
        while (boundaryPosition !== -1) {
          const chunk = buffer.slice(0, boundaryPosition);
          buffer = buffer.slice(boundaryPosition + 2);
          
          if (chunk.startsWith('data: ')) {
            const dataContent = chunk.substring(6);
            if (dataContent === '[DONE]') {
              appendLog('Process Stream Closed.', 'system');
            } else if (dataContent.trim() !== '') {
              appendLog(dataContent, colorizeLogLine(dataContent));
            }
          }
          boundaryPosition = buffer.indexOf('\n\n');
        }
      }
    } catch (error) {
      appendLog(`Execution Error: ${error.message}`, 'error');
    } finally {
      setIsExecuting(false);
    }
  };

  return (
    <div className="app-container">
      <div className="background-orbs">
        <div className="orb orb-1"></div>
        <div className="orb orb-2"></div>
        <div className="orb orb-3"></div>
      </div>

      <header className="app-header glass-panel">
        <h1>OSPC &rarr; FLEX <span>Migrator</span></h1>
        <p>Bridge tool for image portability and first-boot remediation.</p>
      </header>

      <main className="app-main">
        <section className="config-section glass-panel">
          <h2>Migration Configuration</h2>
          
          <form id="migration-form" onSubmit={handleSubmit}>
            
            {/* CORE SETTINGS */}
            <div className="config-group">
              <h3>Core Image Options</h3>
              <div className="form-grid">
                <div className="form-control">
                  <label>OSPC OpenRC Path *</label>
                  <input type="text" name="ospc_openrc" required value={formData.ospc_openrc} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>FLEX OpenRC Path *</label>
                  <input type="text" name="flex_openrc" required value={formData.flex_openrc} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>Source Server Name *</label>
                  <input type="text" name="server_name" required placeholder="web-01" value={formData.server_name} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>Snapshot Name (Optional)</label>
                  <input type="text" name="snapshot_name" placeholder="Auto-generated if empty" value={formData.snapshot_name} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>Target Format</label>
                  <select name="target_format" value={formData.target_format} onChange={handleChange}>
                    <option value="qcow2">qcow2</option>
                    <option value="raw">raw</option>
                  </select>
                </div>
                <div className="form-control">
                  <label>Visibility</label>
                  <select name="visibility" value={formData.visibility} onChange={handleChange}>
                    <option value="private">Private</option>
                    <option value="public">Public</option>
                    <option value="shared">Shared</option>
                    <option value="community">Community</option>
                  </select>
                </div>
              </div>

              <div className="checkbox-group mt-3">
                <label className="toggle-switch">
                  <input type="checkbox" name="dry_run" checked={formData.dry_run} onChange={handleChange} />
                  <span className="slider"></span>
                </label>
                <span className="toggle-label">Dry Run <span>(Print actions without executing)</span></span>
              </div>
              <div className="checkbox-group">
                <label className="toggle-switch">
                  <input type="checkbox" name="cleanup_snapshot" checked={formData.cleanup_snapshot} onChange={handleChange} />
                  <span className="slider"></span>
                </label>
                <span className="toggle-label">Cleanup OSPC Snapshot <span>(Delete OSPC snapshot image after export)</span></span>
              </div>
            </div>

            <hr className="divider" />

            {/* TEST VM SETTINGS */}
            <div className="config-group">
              <div className="group-header">
                <h3>Test VM Options</h3>
                <label className="toggle-switch accent-blue">
                  <input type="checkbox" name="boot_test_vm" checked={formData.boot_test_vm} onChange={handleChange} />
                  <span className="slider"></span>
                </label>
              </div>
              
              <div className={`form-grid collapsable ${!formData.boot_test_vm ? 'collapsed' : ''}`}>
                <div className="form-control">
                  <label>Test Server Name</label>
                  <input type="text" name="test_server_name" placeholder="<server-name>-lift-test" value={formData.test_server_name} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>FLEX Flavor *</label>
                  <input type="text" name="flex_flavor" placeholder="gp.7.1.2" required={formData.boot_test_vm} value={formData.flex_flavor} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>FLEX Network ID *</label>
                  <input type="text" name="flex_network_id" placeholder="UUID" required={formData.boot_test_vm} value={formData.flex_network_id} onChange={handleChange} />
                </div>
                <div className="form-control">
                  <label>FLEX Keypair Name *</label>
                  <input type="text" name="flex_key_name" placeholder="my-key" required={formData.boot_test_vm} value={formData.flex_key_name} onChange={handleChange} />
                </div>
                <div className="form-control form-control-full">
                  <label>Floating IP</label>
                  <input type="text" name="floating_ip" placeholder="e.g. 203.0.113.25" value={formData.floating_ip} onChange={handleChange} />
                </div>
              </div>
            </div>

            <hr className="divider" />

            {/* GUEST REPAIR CONFIG */}
            <div className="config-group">
              <div className="group-header">
                <h3>Guest Repair Options</h3>
                <label className="toggle-switch accent-purple">
                  <input type="checkbox" name="repair_guest" checked={formData.repair_guest} onChange={handleChange} />
                  <span className="slider"></span>
                </label>
              </div>
              
              <div className={`collapsable ${!formData.repair_guest ? 'collapsed' : ''}`}>
                <div className="form-grid mb-3">
                  <div className="form-control form-control-full">
                    <label>SSH Key Path *</label>
                    <input type="text" name="ssh_key_path" placeholder="~/.ssh/id_rsa" required={formData.repair_guest} value={formData.ssh_key_path} onChange={handleChange} />
                  </div>
                  <div className="form-control">
                    <label>SSH User</label>
                    <input type="text" name="ssh_user" value={formData.ssh_user} onChange={handleChange} />
                  </div>
                  <div className="form-control">
                    <label>New Hostname</label>
                    <input type="text" name="new_hostname" placeholder="Set inside guest" value={formData.new_hostname} onChange={handleChange} />
                  </div>
                  <div className="form-control">
                    <label>FLEX Net Interface</label>
                    <input type="text" name="flex_net_iface" placeholder="e.g. ens3" value={formData.flex_net_iface} onChange={handleChange} />
                  </div>
                  <div className="form-control form-control-full">
                    <label>Systemd Services to Restart</label>
                    <input type="text" name="systemd_services" placeholder="nginx,myapp.service" value={formData.systemd_services} onChange={handleChange} />
                  </div>
                </div>
                
                <div className="checkbox-grid">
                  <div className="checkbox-group compact">
                    <input type="checkbox" name="fix_fstab" id="fix_fstab" checked={formData.fix_fstab} onChange={handleChange} />
                    <label htmlFor="fix_fstab">Fix /etc/fstab</label>
                  </div>
                  <div className="checkbox-group compact">
                    <input type="checkbox" name="fix_netplan" id="fix_netplan" checked={formData.fix_netplan} onChange={handleChange} />
                    <label htmlFor="fix_netplan">Write Simple Netplan</label>
                  </div>
                  <div className="checkbox-group compact">
                    <input type="checkbox" name="clean_hosts_file" id="clean_hosts_file" checked={formData.clean_hosts_file} onChange={handleChange} />
                    <label htmlFor="clean_hosts_file">Clean /etc/hosts</label>
                  </div>
                  <div className="checkbox-group compact">
                    <input type="checkbox" name="skip_cloud_init_clean" id="skip_cloud_init_clean" checked={formData.skip_cloud_init_clean} onChange={handleChange} />
                    <label htmlFor="skip_cloud_init_clean">Skip Cloud-init Clean</label>
                  </div>
                </div>
              </div>
            </div>

            <div className="form-actions">
              <button type="submit" className="btn-primary" disabled={isExecuting}>
                {isExecuting ? 'Executing Migration...' : 'Start Migration Task'}
              </button>
            </div>
          </form>
        </section>

        <section className="console-section glass-panel">
          <div className="console-header">
            <div className="window-controls">
              <span className="control red"></span>
              <span className="control yellow"></span>
              <span className="control green"></span>
            </div>
            <span className="console-title">Execution Terminal</span>
            <button className="icon-btn" onClick={clearLogs} title="Clear Console" type="button">
               Clear
            </button>
          </div>
          <div className="console-body" ref={consoleRef}>
            {logs.length === 0 && <div className="log-line system">Waiting for execution...</div>}
            {logs.map((log, idx) => (
              <div key={idx} className={`log-line ${log.type}`}>
                {log.text}
              </div>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}

export default App;
