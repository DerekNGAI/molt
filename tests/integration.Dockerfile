FROM docker:28-dind
RUN apk add --no-cache bash coreutils openssh-server git curl procps iproute2
RUN ssh-keygen -A && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' >> /etc/ssh/sshd_config
CMD ["sh", "-c", "cat /test-key.pub > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && /usr/sbin/sshd && exec dockerd --host=unix:///var/run/docker.sock"]
