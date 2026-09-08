FROM vbatts/slackware:15.0
MAINTAINER perrin4869 <julian@dotcore.co.il>

ARG REPO="http://slackware.osuosl.org/slackware64-15.0/"
ARG SBOPKG_VERSION="0.38.3"
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
    wget -c "https://github.com/sbopkg/sbopkg/releases/download/${SBOPKG_VERSION}/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz" && \
    installpkg "sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"

RUN sbopkg -r
RUN sqg -a
RUN sbopkg -B -i sbo-maintainer-tools

WORKDIR /root

CMD bash -l
