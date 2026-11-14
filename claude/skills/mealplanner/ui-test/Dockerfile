# Mobile UI tests for the Home Kitchen web app. Browsers come prebuilt in Microsoft's image (pinned by digest),
# and the playwright library is installed from the lockfile with install scripts off, inside the image only.
FROM mcr.microsoft.com/playwright:v1.57.0-noble@sha256:3bed4b1a12f2338642f3d8cba28e291deef3c66bd4a964bbeb3e57bbff511dbd
WORKDIR /t
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund --omit=optional && npm cache clean --force
USER pwuser
