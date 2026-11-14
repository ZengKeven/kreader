FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
WORKDIR /src
COPY server/NovelServer.csproj server/
RUN dotnet restore server/NovelServer.csproj
COPY validation/prepare-sources.ps1 validation/
RUN pwsh -NoLogo -NoProfile -File validation/prepare-sources.ps1
COPY server/*.cs server/
RUN dotnet publish server/NovelServer.csproj -c Release --no-restore \
    --no-self-contained -p:UseAppHost=false -o /out \
    && test -s /out/starter-sources.json

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 -o app -g app /data
WORKDIR /app
COPY --from=build /out/ ./
ENV ASPNETCORE_URLS=http://0.0.0.0:7187 \
    NOVEL_DATA=/data
USER app
EXPOSE 7187
HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:7187/health >/dev/null || exit 1
ENTRYPOINT ["dotnet", "NovelServer.dll"]
