FROM debian:bookworm-slim

# ARG only, never ENV, for DEBIAN_FRONTEND -- an ENV would leak into the running container.
ARG DEBIAN_FRONTEND=noninteractive
ARG WINEBRANCH=stable
ARG WINEVERSION=11.0.0.0~bookworm-1
ARG WINETRICKS_COMMIT=08304e81f9ac9a83c552a6bd78689040d174bf95
ARG WINETRICKS_SHA256=954d17f56ae5f4d32eb083193a4a838c73ae5ff6b91765d93b0eab59cf2e7d29

# /wineprefix is the ONE prefix path. The predecessor also set /root/server, which was dead.
ENV WINEARCH=win64 \
    WINEPREFIX=/wineprefix \
    WINEDEBUG=-all \
    DISPLAY=:99

# WineHQ repo + pinned Wine. An unavailable pin fails the build here, loudly.
RUN dpkg --add-architecture i386 && \
    apt-get -qq update && \
    apt-get install -y -qq --no-install-recommends ca-certificates wget && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources && \
    apt-get -qq update && \
    apt-get install -y -qq --install-recommends \
      winehq-${WINEBRANCH}=${WINEVERSION} \
      wine-${WINEBRANCH}=${WINEVERSION} \
      wine-${WINEBRANCH}-amd64=${WINEVERSION} \
      wine-${WINEBRANCH}-i386=${WINEVERSION} && \
    apt-get install -y -qq --no-install-recommends \
      xvfb x11-utils x11vnc openbox winbind cabextract procps unzip \
      libfaudio0 libfaudio0:i386 \
      lib32gcc-s1 && \
    rm -rf /var/lib/apt/lists/* && \
    echo "pinned Wine: ${WINEVERSION}" && wine --version

# Native Linux steamcmd, used to install the SE dedicated server (app 298740) with
# @sSteamCmdForcePlatformType windows. Torch's own updater runs the WINDOWS steamcmd under Wine,
# which fails with "Failed installing AppID 298740 (Missing configuration)" -- it never retrieves
# appinfo, then reports success anyway, leaving Torch to die on the absent DedicatedServer64/.
# So we install SE ourselves and run Torch with -noupdate. lib32gcc-s1 is steamcmd's 32-bit loader.
RUN mkdir -p /opt/steamcmd && \
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
      | tar -xz -C /opt/steamcmd

# Pinned winetricks with a checksum, so upstream cannot silently change the prefix.
RUN wget -qO /usr/local/bin/winetricks \
      "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks" && \
    echo "${WINETRICKS_SHA256}  /usr/local/bin/winetricks" | sha256sum -c - && \
    chmod +x /usr/local/bin/winetricks

# uid 1000 is load-bearing: docker-compose bind-mounts ./torch-server here and Torch must write to it.
RUN adduser --disabled-password --gecos "" --uid 1000 wine && \
    mkdir -p /wineprefix /app /scripts && \
    chown -R wine:wine /wineprefix /app /opt/steamcmd

# The expensive layer. Everything below it should stay below it.
COPY winetricks.sh /scripts/winetricks.sh
RUN chmod +x /scripts/winetricks.sh && \
    runuser -u wine -- /scripts/winetricks.sh

# Xvfb runs as `wine` at runtime and cannot create this itself (euid != 0).
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

WORKDIR /app
EXPOSE 5900 27016/udp

# Last layer on purpose: entrypoint edits must not invalidate the winetricks layer above.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
