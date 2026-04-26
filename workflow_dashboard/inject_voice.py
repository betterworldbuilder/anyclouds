import sys
import re

with open('templates/image_migrator.html', 'r', encoding='utf-8') as f:
    text = f.read()

# 1. UI Toggle
ui_injection = '''
                    <div style="margin: 0 0 16px 0; padding: 10px 18px; background: rgba(139,92,246,0.08); border: 1px solid rgba(139,92,246,0.3); border-radius: 10px; display: flex; align-items: center; gap: 15px; flex-wrap: wrap;">
                        <label style="color:#c4b5fd; font-size:0.9rem; font-weight:600; display:flex; align-items:center; gap:10px; cursor:pointer;">
                            <input type="checkbox" id="enable_jarvis_voice" checked style="width:16px; height:16px; accent-color:#8b5cf6; cursor:pointer;" onchange="localStorage.setItem('mig_jarvis_voice', this.checked);">
                            🎙️ Jarvis Pipeline Audio Alerts
                        </label>
                        <button type="button" onclick="jarvisAnnounce('Audio sub-systems on-line and standing by.')" style="background:rgba(255,255,255,0.05); border:1px solid rgba(255,255,255,0.1); color:#94a3b8; font-size:0.75rem; padding:3px 10px; border-radius:4px; cursor:pointer; transition:0.2s;">Test Voice</button>
                    </div>
'''
if '🎙️ Jarvis Pipeline Audio Alerts' not in text:
    text = text.replace('<input type="hidden" id="mig_mode_value" value="live">', ui_injection + '\n                    <input type="hidden" id="mig_mode_value" value="live">')

# 2. Add jarvisAnnounce(text) function
js_injection = '''
// --- Jarvis Audio Subsystem ---
document.addEventListener('DOMContentLoaded', () => {
    const saved = localStorage.getItem('mig_jarvis_voice');
    if (saved !== null) document.getElementById('enable_jarvis_voice').checked = (saved === 'true');
});

function jarvisAnnounce(text) {
    const toggle = document.getElementById('enable_jarvis_voice');
    if (!toggle || !toggle.checked) return;
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(text);
    const voices = window.speechSynthesis.getVoices();
    const jarvisVoice = voices.find(v => v.name.includes("UK English Male")) || voices.find(v => v.lang === "en-GB");
    if (jarvisVoice) utterance.voice = jarvisVoice;
    utterance.rate = 1.05;
    utterance.pitch = 0.9;
    window.speechSynthesis.speak(utterance);
}
// ------------------------------
'''
if 'function jarvisAnnounce' not in text:
    text = text.replace("const evtSource = new EventSource('/sse');", js_injection + "\n        const evtSource = new EventSource('/sse');")

# 3. Hook runBatch start
if 'jarvisAnnounce(`Initiating' not in text:
    text = text.replace("appendLog('⚠ All selected VMs are already running. No new jobs dispatched.', 'system');", 
                        "jarvisAnnounce(`Job aborted. All selected payloads are already running.`);\n                appendLog('⚠ All selected VMs are already running. No new jobs dispatched.', 'system');")
    
    text = text.replace("const tsBatch = new Date().toLocaleTimeString();", 
                        "jarvisAnnounce(`Initiating migration sequence for ${_newCheckedVMs.length} servers. Please stand by.`);\n            const tsBatch = new Date().toLocaleTimeString();")

# 4. Error Hook: In parseRemoteLine or setVmStatus
if 'jarvisAnnounce(`Warning. Migration failure' not in text:
    # hook setVmStatus
    text = text.replace("if (status === 'error') {\n                    card.style.borderColor = '#ef4444';",
                        "if (status === 'error') {\n                    jarvisAnnounce(`Warning. Migration failure detected for target ${vmName}. Please check the logs.`);\n                    card.style.borderColor = '#ef4444';")

# 5. Success Hook: When all jobs end
if 'jarvisAnnounce(`Migration sequence completed' not in text:
    # runOneVM loop finish
    text = text.replace("startBtn.disabled = false;",
                        "if (!Array.from(checkedVMs).some(cb => document.getElementById(\"vm-block-\" + cb.dataset.sourceName.replace(/[^a-zA-Z0-9_-]/g, '_'))?.querySelector('.vm-status').textContent === 'Deploying...')) {\n                        jarvisAnnounce(`Migration sequence completed successfully. All payloads have been secured.`);\n                    }\n                    startBtn.disabled = false;")

with open('templates/image_migrator.html', 'w', encoding='utf-8') as f:
    f.write(text)
print('Patched successfully.')
