// Filter rows by text; toggle dark mode (remembered across pages).
(function () {
  const input = document.getElementById('filter');
  const blocks = Array.from(document.querySelectorAll('.block'));

  function applyFilter() {
    const query = input.value.trim().toLowerCase();
    for (const block of blocks) {
      let shown = 0;
      for (const row of block.querySelectorAll('.l')) {
        const section = row.classList.contains('s');
        const match = !query || (!section && row.textContent.toLowerCase().includes(query));
        row.classList.toggle('hidden', query !== '' && !match);
        if (match && !section) shown++;
      }
      block.classList.toggle('hidden', query !== '' && shown === 0);
    }
  }

  input.addEventListener('input', applyFilter);
  document.addEventListener('keydown', function (event) {
    if (event.key === '/' && document.activeElement !== input) {
      event.preventDefault();
      input.focus();
    } else if (event.key === 'Escape' && document.activeElement === input) {
      input.value = '';
      applyFilter();
      input.blur();
    }
  });

  document.getElementById('dark').addEventListener('click', function () {
    const dark = document.documentElement.classList.toggle('dark');
    localStorage.setItem('dark', dark ? '1' : '0');
  });
})();
