# example-workflows/

On a real metarepo these files live under `.github/workflows/`. They are
relocated here on the static example branch because the auto-publish job
pushes with the default GITHUB_TOKEN, which GitHub forbids from writing
workflow files. Copy them back to .github/workflows/ in your own metarepo.
