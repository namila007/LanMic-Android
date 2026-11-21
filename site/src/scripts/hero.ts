// One rAF clock drives the hero loop: it only sets data-* flags, CSS does the animating.
const LOOP = 9000;
const scene = document.querySelector<HTMLElement>('[data-scene]');
const steps = document.querySelectorAll<HTMLElement>('[data-step]');
const ms = scene?.querySelector<HTMLElement>('[data-ms]');
const FLAGS = ['typed', 'connected', 'talking', 'badge', 'fade'] as const;

function setStep(n: number): void {
  steps.forEach((el) => el.toggleAttribute('data-active', Number(el.dataset.step) === n));
}

function frame(t: number): void {
  if (!scene || !ms) return;
  const on: Record<(typeof FLAGS)[number], boolean> = {
    typed: t >= 1500,
    connected: t >= 3000,
    talking: t >= 4000 && t < 7000,
    badge: t >= 4500,
    fade: t >= 8400,
  };
  for (const f of FLAGS) scene.toggleAttribute(`data-${f}`, on[f]);
  ms.textContent = String(Math.round(75 * Math.min(1, Math.max(0, (t - 4500) / 1500))));
  setStep(t < 1500 ? 1 : t < 4000 ? 2 : 3);
}

if (scene) {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setStep(3); // markup already holds the static final frame
  } else {
    let t = 0;
    let last = performance.now();
    let visible = true;
    const tick = (now: number): void => {
      if (visible) t = (t + now - last) % LOOP;
      last = now;
      frame(t);
      requestAnimationFrame(tick);
    };
    new IntersectionObserver(([e]) => (visible = e.isIntersecting)).observe(scene);
    requestAnimationFrame(tick);
  }
}
