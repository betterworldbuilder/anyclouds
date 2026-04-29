/**
 * Shared Jarvis TTS: original British male/female browser voices.
 * Uses #enable_jarvis_voice / #jarvis_voice_gender when present (image migrator),
 * else localStorage mig_jarvis_voice / mig_jarvis_gender (default on, male).
 * Call jarvisAnnounce(text) or jarvisSpeakBritish(text) from any stage.
 */
(function () {
  'use strict';

  function voiceEnabled() {
    var el = document.getElementById('enable_jarvis_voice');
    if (el) return !!el.checked;
    return localStorage.getItem('mig_jarvis_voice') !== 'false';
  }

  function voiceGender() {
    var g = document.getElementById('jarvis_voice_gender');
    if (g && g.value) return g.value;
    var ls = localStorage.getItem('mig_jarvis_gender');
    if (ls === 'female' || ls === 'male') return ls;
    return 'male';
  }

  function pickBritishVoice(voices, gender) {
    var preferred;
    if (gender === 'female') {
      preferred = voices.find(function (v) {
        return v.name.includes('Google UK English Female') || v.name.includes('Hazel') || v.name.includes('Serena') ||
          v.name.includes('Fiona') || v.name.includes('Susan') || (v.lang === 'en-GB' && v.name.includes('Female'));
      });
    } else {
      preferred = voices.find(function (v) {
        return v.name.includes('Google UK English Male') || v.name.includes('Daniel') || v.name.includes('George') ||
          v.name.includes('Arthur') || (v.lang === 'en-GB' && v.name.includes('Male'));
      });
    }
    if (!preferred) preferred = voices.find(function (v) { return v.lang === 'en-GB'; }) || voices[0];
    return preferred;
  }

  function speak(text) {
    if (!text) return;
    if (!voiceEnabled()) return;
    if (!('speechSynthesis' in window)) return;

    window.speechSynthesis.cancel();
    var msg = new SpeechSynthesisUtterance(text);
    var gender = voiceGender();

    function setVoiceAndSpeak() {
      var voices = window.speechSynthesis.getVoices();
      var preferred = pickBritishVoice(voices, gender);
      if (preferred) msg.voice = preferred;
      msg.rate = 1.0;
      msg.pitch = gender === 'female' ? 1.15 : 0.95;
      window.speechSynthesis.speak(msg);
    }

    if (window.speechSynthesis.getVoices().length === 0) {
      window.speechSynthesis.addEventListener('voiceschanged', setVoiceAndSpeak, { once: true });
    } else {
      setVoiceAndSpeak();
    }
  }

  window.jarvisSpeakBritish = speak;
  window.jarvisAnnounce = speak;
})();
