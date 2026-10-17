#ifndef HEADER_CURL_CONFIG_LINUX_H
#define HEADER_CURL_CONFIG_LINUX_H
/*
 * curl_config.h for x86_64-linux-gnu (glibc), written by hand for the
 * engine's HTTP(S)-only libcurl -- what curl's own CMake would generate on
 * glibc, cut to what this build uses. Windows needs none of it: curl_setup.h
 * takes lib/config-win32.h there, HAVE_CONFIG_H undefined.
 *
 *   TLS        mbedTLS (vendor/mbedtls, 3.6) -- Windows uses Schannel
 *   HTTP/2     nghttp2 (vendor/nghttp2), gzip/deflate via zlib (vendor/zlib)
 *   DNS        the threaded resolver over getaddrinfo, IPv6 on
 *   trust      CURL_CA_PATH /etc/ssl/certs: the system's certificate folder.
 *              A folder, not a bundle FILE, because the bundle's name differs
 *              by distribution (Debian/Ubuntu/Alpine ca-certificates.crt,
 *              Fedora/RHEL ca-bundle.crt) and every one of them lays the
 *              folder out; mbedTLS reads every certificate in it.
 *
 * Built with -D_GNU_SOURCE, so strerror_r is glibc's (HAVE_GLIBC_STRERROR_R).
 */

#define CURL_OS "x86_64-pc-linux-gnu"

/* ---- features ---------------------------------------------------------- */
#define USE_MBEDTLS 1
#define CURL_CA_PATH "/etc/ssl/certs"
#define USE_RESOLV_THREADED 1
#define HAVE_THREADS_POSIX 1
#define HAVE_PTHREAD_H 1
#define USE_IPV6 1
#define USE_UNIX_SOCKETS 1

/* ---- headers ----------------------------------------------------------- */
#define HAVE_ARPA_INET_H 1
#define HAVE_DIRENT_H 1
#define HAVE_FCNTL_H 1
#define HAVE_IFADDRS_H 1
#define HAVE_LIBGEN_H 1
#define HAVE_LINUX_TCP_H 1
#define HAVE_LOCALE_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NETINET_UDP_H 1
#define HAVE_NET_IF_H 1
#define HAVE_POLL_H 1
#define HAVE_PWD_H 1
#define HAVE_STDATOMIC_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_EVENTFD_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_POLL_H 1
#define HAVE_SYS_RESOURCE_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_TERMIOS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_UTIME_H 1

/* ---- functions and types ----------------------------------------------- */
#define HAVE_ACCEPT4 1
#define HAVE_ALARM 1
#define HAVE_ATOMIC 1
#define HAVE_BASENAME 1
#define HAVE_BOOL_T 1
#define HAVE_CLOCK_GETTIME_MONOTONIC 1
#define HAVE_CLOCK_GETTIME_MONOTONIC_RAW 1
#define HAVE_DECL_FSEEKO 1
#define HAVE_EVENTFD 1
#define HAVE_FCNTL 1
#define HAVE_FCNTL_O_NONBLOCK 1
#define HAVE_FREEADDRINFO 1
#define HAVE_FSEEKO 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETADDRINFO_THREADSAFE 1
#define HAVE_GETEUID 1
#define HAVE_GETHOSTBYNAME_R 1
#define HAVE_GETHOSTBYNAME_R_6 1
#define HAVE_GETHOSTNAME 1
#define HAVE_GETIFADDRS 1
#define HAVE_GETPEERNAME 1
#define HAVE_GETPPID 1
#define HAVE_GETPWUID 1
#define HAVE_GETPWUID_R 1
#define HAVE_GETRLIMIT 1
#define HAVE_GETSOCKNAME 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_GLIBC_STRERROR_R 1
#define HAVE_GMTIME_R 1
#define HAVE_IF_NAMETOINDEX 1
#define HAVE_INET_NTOP 1
#define HAVE_INET_PTON 1
#define HAVE_IOCTL_FIONBIO 1
#define HAVE_IOCTL_SIOCGIFADDR 1
#define HAVE_LOCALTIME_R 1
#define HAVE_MEMRCHR 1
#define HAVE_MSG_NOSIGNAL 1
#define HAVE_OPENDIR 1
#define HAVE_PIPE 1
#define HAVE_PIPE2 1
#define HAVE_POLL 1
#define HAVE_REALPATH 1
#define HAVE_SA_FAMILY_T 1
#define HAVE_SCHED_YIELD 1
#define HAVE_SELECT 1
#define HAVE_SENDMSG 1
#define HAVE_SETLOCALE 1
#define HAVE_SETRLIMIT 1
#define HAVE_SIGACTION 1
#define HAVE_SIGNAL 1
#define HAVE_SIGSETJMP 1
#define HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID 1
#define HAVE_SOCKET 1
#define HAVE_SOCKETPAIR 1
#define HAVE_STRERROR_R 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_TIMEVAL 1
#define HAVE_SUSECONDS_T 1
#define HAVE_UTIME 1
#define HAVE_UTIMES 1

/* recv() and send(), as curl_setup.h requires them spelled out */
#define HAVE_RECV 1
#define RECV_TYPE_ARG1 int
#define RECV_TYPE_ARG2 void *
#define RECV_TYPE_ARG3 size_t
#define RECV_TYPE_ARG4 int
#define RECV_TYPE_RETV ssize_t
#define HAVE_SEND 1
#define SEND_TYPE_ARG1 int
#define SEND_TYPE_ARG2 void *
#define SEND_TYPE_ARG3 size_t
#define SEND_TYPE_ARG4 int
#define SEND_TYPE_RETV ssize_t

/* ---- sizes, x86_64 LP64 ------------------------------------------------ */
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_OFF_T 8
#define SIZEOF_CURL_OFF_T 8
#define SIZEOF_CURL_SOCKET_T 4
#define SIZEOF_SIZE_T 8
#define SIZEOF_TIME_T 8

#endif /* HEADER_CURL_CONFIG_LINUX_H */
