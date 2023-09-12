FROM vbatts/slackware:15.0
MAINTAINER perrin4869 <julian@dotcore.co.il>

ARG DEV_UID=1000
ARG DEV_GID=1000
ARG DEV_USER=limited
ARG REPO="http://slackware.osuosl.org/slackware64-15.0/"
RUN echo "${REPO}" > /etc/slackpkg/mirrors
RUN yes y | slackpkg update gpg && \
    slackpkg update && \
    slackpkg install-new && \
    slackpkg upgrade-all -default_answer=yes -batch=yes && \
    slackpkg install -default_answer=yes -batch=yes a ap n d k l kde x t xap xfce y

# from the slackware source tree source/n/ca-certificates/setup.11.cacerts
# runs c_rehash instead of openssl rehash
RUN update-ca-certificates --fresh

RUN \
    mkdir -p /tmp/install && cd /tmp/install && \
    wget -c https://github.com/sbopkg/sbopkg/releases/download/0.38.2/sbopkg-0.38.2-noarch-1_wsr.tgz && \
    installpkg sbopkg-0.38.2-noarch-1_wsr.tgz

RUN sbopkg -r

RUN groupadd -g "${DEV_GID}" "${DEV_USER}" ; \
    useradd -m -u "${DEV_UID}" -g "${DEV_GID}" -G wheel "${DEV_USER}" && \
    sed -ri 's/^# (%wheel.*NOPASSWD.*)$/\1/' /etc/sudoers

USER "${DEV_USER}"
ENV HOME /home/"${DEV_USER}"
WORKDIR /home/"${DEV_USER}"

CMD bash -l
