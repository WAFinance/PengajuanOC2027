name: Deploy Worker

on:
  push:
    branches: [main]   # ganti ke "master" jika branch utama kamu bernama master

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Deploy Worker
        uses: cloudflare/wrangler-action@v3
        with:
          apiToken: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          workingDirectory: "."   # sesuaikan jika worker.js tidak di root repo

      - name: Set Google secrets
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
        run: |
          echo "${{ secrets.GOOGLE_CLIENT_ID }}"     | npx wrangler secret put GOOGLE_CLIENT_ID
          echo "${{ secrets.GOOGLE_CLIENT_SECRET }}" | npx wrangler secret put GOOGLE_CLIENT_SECRET
          echo "${{ secrets.GOOGLE_REFRESH_TOKEN }}" | npx wrangler secret put GOOGLE_REFRESH_TOKEN
