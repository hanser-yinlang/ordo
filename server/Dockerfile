# Ordo 后端镜像(多阶段:构建 → 仅生产依赖运行)
# 构建:docker build -t ordo-server:1.0.0 .

FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN pnpm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile --prod
COPY --from=build /app/dist ./dist
# 迁移脚本运行时要读 SQL 文件
COPY src/repo/migrations ./dist/repo/migrations
# 以非 root 用户运行
RUN addgroup -S ordo && adduser -S ordo -G ordo && chown -R ordo:ordo /app
USER ordo
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
