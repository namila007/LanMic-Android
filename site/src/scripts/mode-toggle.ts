// Hold-to-talk vs Keep-talking demo: radios set the mode, the mic reflects it.
const demo = document.querySelector<HTMLElement>('[data-mode-demo]');
const mic = demo?.querySelector<HTMLButtonElement>('[data-mic]');
const label = demo?.querySelector<HTMLElement>('[data-mic-label]');

if (demo && mic && label) {
  const talk = (on: boolean): void => {
    mic.toggleAttribute('data-on', on);
    label.textContent = on ? 'Talking' : demo.dataset.mode === 'keep' ? 'Tap to talk' : 'Hold to talk';
  };
  demo.querySelectorAll<HTMLInputElement>('input[name="mode"]').forEach((r) =>
    r.addEventListener('change', () => {
      demo.dataset.mode = r.value;
      talk(r.value === 'keep');
    }),
  );
  mic.addEventListener('pointerdown', () => demo.dataset.mode === 'hold' && talk(true));
  ['pointerup', 'pointerleave', 'pointercancel'].forEach((e) =>
    mic.addEventListener(e, () => demo.dataset.mode === 'hold' && talk(false)),
  );
  mic.addEventListener('click', () => demo.dataset.mode === 'keep' && talk(!mic.hasAttribute('data-on')));
  mic.addEventListener('keydown', (e) => {
    if (demo.dataset.mode === 'hold' && (e.key === ' ' || e.key === 'Enter')) talk(true);
  });
  mic.addEventListener('keyup', () => demo.dataset.mode === 'hold' && talk(false));
}
