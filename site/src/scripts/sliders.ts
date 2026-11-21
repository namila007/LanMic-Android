// Two demo sliders (-12..+12 dB). Reads data-out (label id) and data-warn (chip id).
document.querySelectorAll<HTMLInputElement>('input[data-slider]').forEach((input) => {
  const out = document.getElementById(input.dataset.out ?? '');
  const warn = document.getElementById(input.dataset.warn ?? '');
  const bar = document.getElementById(input.dataset.bar ?? '');
  const update = (): void => {
    const db = Number(input.value);
    if (out) out.textContent = `${db > 0 ? '+' : db < 0 ? '−' : ''}${Math.abs(db)} dB`;
    if (warn) warn.hidden = db < 12;
    if (bar) bar.style.transform = `scaleX(${(db + 12) / 24})`;
  };
  input.addEventListener('input', update);
  update();
});
