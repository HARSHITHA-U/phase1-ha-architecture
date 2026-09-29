#!/bin/bash
dnf install -y httpd
echo "<h1>Served by $(hostname -f)</h1>" > /var/www/html/index.html

mkdir -p /var/www/cgi-bin
cat > /var/www/cgi-bin/burn <<'CGI'
#!/bin/bash
echo "Content-type: text/plain"
echo ""
echo "burning cpu on $(hostname -f) for 300s"
for i in $(seq $(nproc)); do
  (timeout 300 sh -c 'while :; do :; done' </dev/null >/dev/null 2>&1 &)
done
CGI
chmod +x /var/www/cgi-bin/burn

systemctl enable --now httpd
