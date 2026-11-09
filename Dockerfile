FROM node:20-alpine
WORKDIR /app
COPY server.js ./
RUN mkdir -p /app/data
ENV PORT=8787
ENV DATA_DIR=/app/data
EXPOSE 8787
CMD ["node", "server.js"]
