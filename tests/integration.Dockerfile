FROM docker:28-dind
RUN apk add --no-cache bash coreutils openssh-server git curl procps iproute2
RUN ssh-keygen -A && adduser -D -s /bin/bash -G docker molt-test && passwd -d molt-test \
    && mkdir -p /home/molt-test/.ssh && chmod 700 /home/molt-test/.ssh \
    && printf 'PasswordAuthentication no\n' >> /etc/ssh/sshd_config
CMD ["sh", "-c", "cat /test-key.pub > /home/molt-test/.ssh/authorized_keys && chmod 600 /home/molt-test/.ssh/authorized_keys && chown -R molt-test:docker /home/molt-test/.ssh && /usr/sbin/sshd && exec dockerd --host=unix:///var/run/docker.sock"]
