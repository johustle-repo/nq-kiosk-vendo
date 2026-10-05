// Confirmation for destructive plain forms (CSP-safe: no inline handlers).
document.addEventListener('submit', (e) => {
    const form = e.target.closest('form[data-confirm]');
    if (form && !window.confirm(form.dataset.confirm)) {
        e.preventDefault();
    }
});
