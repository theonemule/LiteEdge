(() => {
  function showStatus(form, message, isError) {
    let status = form.querySelector(".bundle-import-status");
    if (!status) {
      status = document.createElement("div");
      status.className = "bundle-import-status mt-2 small";
      form.appendChild(status);
    }
    status.className = "bundle-import-status mt-2 small " + (isError ? "text-danger" : "text-success");
    status.textContent = message;
  }

  document.addEventListener("submit", async (event) => {
    const form = event.target.closest(".bundle-import-form");
    if (!form) return;

    event.preventDefault();
    const fileInput = form.querySelector('input[type="file"]');
    const file = fileInput && fileInput.files && fileInput.files[0];
    if (!file) {
      showStatus(form, "Choose a LiteEdge bundle first.", true);
      return;
    }

    const params = new URLSearchParams();
    params.set("scope", form.dataset.scope || "");
    if (form.dataset.host) params.set("host", form.dataset.host);
    const certBox = form.querySelector('input[name="certificates"]');
    params.set("certificates", certBox && certBox.checked ? "1" : "0");

    const button = form.querySelector('button[type="submit"]');
    if (button) button.disabled = true;
    showStatus(form, "Importing and validating bundle…", false);

    try {
      const response = await fetch("/admin/import?" + params.toString(), {
        method: "POST",
        headers: {"Content-Type": "application/octet-stream"},
        body: file
      });
      const text = await response.text();
      if (!response.ok) throw new Error(text || "Import failed.");
      showStatus(form, text || "Import complete.", false);
      window.location.assign(form.dataset.redirect || "/");
    } catch (error) {
      showStatus(form, error.message || String(error), true);
    } finally {
      if (button) button.disabled = false;
    }
  });
})();
