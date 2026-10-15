FROM alpine:3.22
RUN apk add --no-cache openssh nodejs && ssh-keygen -A && passwd -d root && mkdir -p /root/.ssh /run/sshd
COPY authorized_keys /root/.ssh/authorized_keys
COPY server.mjs /server.mjs
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
CMD ["/bin/sh", "-c", "node /server.mjs & exec /usr/sbin/sshd -D -e -o PermitRootLogin=yes -o PasswordAuthentication=no -o AllowTcpForwarding=yes"]
