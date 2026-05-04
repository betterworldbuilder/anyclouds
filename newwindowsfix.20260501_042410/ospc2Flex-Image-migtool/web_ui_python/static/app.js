document.addEventListener('DOMContentLoaded', () => {
    // Toggles logic for expanding/collapsing sections
    const bootTestVmToggle = document.getElementById('boot_test_vm');
    const testVmFields = document.getElementById('test-vm-fields');
    
    bootTestVmToggle.addEventListener('change', (e) => {
        if (e.target.checked) {
            testVmFields.classList.remove('collapsed');
            // Make core test fields required
            document.getElementById('flex_flavor').required = true;
            document.getElementById('flex_network_id').required = true;
            document.getElementById('flex_key_name').required = true;
        } else {
            testVmFields.classList.add('collapsed');
            document.getElementById('flex_flavor').required = false;
            document.getElementById('flex_network_id').required = false;
            document.getElementById('flex_key_name').required = false;
        }
    });

    const repairGuestToggle = document.getElementById('repair_guest');
    const guestRepairFields = document.getElementById('guest-repair-fields');

    repairGuestToggle.addEventListener('change', (e) => {
        if (e.target.checked) {
            guestRepairFields.classList.remove('collapsed');
            document.getElementById('ssh_key_path').required = true;
            
            // Auto-check boot test vm if guest repair is checked, as it's required
            if (!bootTestVmToggle.checked) {
                bootTestVmToggle.checked = true;
                bootTestVmToggle.dispatchEvent(new Event('change'));
            }
        } else {
            guestRepairFields.classList.add('collapsed');
            document.getElementById('ssh_key_path').required = false;
        }
    });

    // Console clear logic
    const consoleOutput = document.getElementById('console-output');
    const clearBtn = document.getElementById('clear-log-btn');
    
    clearBtn.addEventListener('click', () => {
        consoleOutput.innerHTML = '<div class="log-line system">Console cleared.</div>';
    });

    function appendLog(text, type = 'info') {
        const line = document.createElement('div');
        line.className = `log-line ${type}`;
        line.textContent = text;
        consoleOutput.appendChild(line);
        consoleOutput.scrollTop = consoleOutput.scrollHeight;
    }

    function colorizeLogLine(text) {
        if (text.includes('--- EXECUTING ---')) return 'command';
        if (text.includes('[OK]') || text.includes('[DONE]')) return 'success';
        if (text.includes('[ERROR]') || text.includes('failed')) return 'error';
        if (text.includes('[INFO]')) return 'info';
        return 'info';
    }

    // Form Submit
    const form = document.getElementById('migration-form');
    const startBtn = document.getElementById('start-btn');

    form.addEventListener('submit', async (e) => {
        e.preventDefault();
        
        // Prepare payload
        const formData = new FormData(form);
        const payload = {};
        
        // Handle all inputs
        form.querySelectorAll('input, select').forEach(input => {
            if (input.type === 'checkbox') {
                payload[input.name] = input.checked;
            } else if (input.type === 'number') {
                payload[input.name] = input.value ? parseInt(input.value) : null;
            } else {
                payload[input.name] = input.value;
            }
        });

        startBtn.disabled = true;
        startBtn.innerHTML = '<svg class="animate-spin" style="animation: spin 1s linear infinite;" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="2" x2="12" y2="6"></line><line x1="12" y1="18" x2="12" y2="22"></line><line x1="4.93" y1="4.93" x2="7.76" y2="7.76"></line><line x1="16.24" y1="16.24" x2="19.07" y2="19.07"></line><line x1="2" y1="12" x2="6" y2="12"></line><line x1="18" y1="12" x2="22" y2="12"></line><line x1="4.93" y1="19.07" x2="7.76" y2="16.24"></line><line x1="16.24" y1="7.76" x2="19.07" y2="4.93"></line></svg> Executing...';
        appendLog(`\n============= NEW RUN =============`, 'system');

        try {
            const response = await fetch('/api/run', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            if (!response.body) throw new Error("ReadableStream not yet supported in this browser.");
            
            const reader = response.body.getReader();
            const decoder = new TextDecoder('utf-8');
            let buffer = '';

            while (true) {
                const { value, done } = await reader.read();
                if (done) break;
                
                buffer += decoder.decode(value, { stream: true });
                
                // Process lines ending in \n\n (SSE format)
                let boundaryPosition = buffer.indexOf('\n\n');
                while (boundaryPosition !== -1) {
                    const chunk = buffer.slice(0, boundaryPosition);
                    buffer = buffer.slice(boundaryPosition + 2);
                    
                    if (chunk.startsWith('data: ')) {
                        const dataContent = chunk.substring(6);
                        
                        // We hit the end token
                        if (dataContent === '[DONE]') {
                            appendLog('Process Stream Closed.', 'system');
                        } else {
                            if (dataContent.trim() !== '') {
                                appendLog(dataContent, colorizeLogLine(dataContent));
                            }
                        }
                    }
                    boundaryPosition = buffer.indexOf('\n\n');
                }
            }
        } catch (error) {
            appendLog(`Fetch Error: ${error.message}`, 'error');
        } finally {
            startBtn.disabled = false;
            startBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg> Start Migration Task';
        }
    });

    // Add extra spin animation keyframe
    const style = document.createElement('style');
    style.innerHTML = `@keyframes spin { 100% { transform: rotate(360deg); } }`;
    document.head.appendChild(style);
});
