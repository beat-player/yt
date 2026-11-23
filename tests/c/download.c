/* Loads the library `lde compile --shared` builds and downloads a video through its C API.
 * usage: download <library> <video> <dir>
 * Prints the info JSON and then the downloaded path; exits non-zero on any failure. */
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#define OPEN(path) ((void *)LoadLibraryA(path))
#define SYM(lib, name) ((void *)GetProcAddress((HMODULE)(lib), name))
#else
#include <dlfcn.h>
#define OPEN(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
#define SYM(lib, name) dlsym(lib, name)
#endif

typedef const char *(*yt_download_fn)(const char *input, const char *dir, const char *cache_dir);
typedef const char *(*yt_info_fn)(const char *input, const char *cache_dir);
typedef const char *(*yt_error_fn)(void);

int main(int argc, char **argv) {
	if (argc != 4) {
		fprintf(stderr, "usage: %s <library> <video> <dir>\n", argv[0]);
		return 2;
	}

	void *lib = OPEN(argv[1]);
	if (!lib) {
		fprintf(stderr, "cannot load %s\n", argv[1]);
		return 1;
	}

	yt_download_fn yt_download = (yt_download_fn)SYM(lib, "yt_download");
	yt_info_fn yt_info = (yt_info_fn)SYM(lib, "yt_info");
	yt_error_fn yt_error = (yt_error_fn)SYM(lib, "yt_error");
	if (!yt_download || !yt_info || !yt_error) {
		fprintf(stderr, "missing yt_* exports\n");
		return 1;
	}

	const char *info = yt_info(argv[2], NULL);
	if (!info) {
		fprintf(stderr, "yt_info: %s\n", yt_error());
		return 1;
	}
	printf("%s\n", info);

	const char *path = yt_download(argv[2], argv[3], NULL);
	if (!path) {
		fprintf(stderr, "yt_download: %s\n", yt_error());
		return 1;
	}
	printf("%s\n", path);

	if (yt_download("not a video", argv[3], NULL) != NULL || yt_error() == NULL) {
		fprintf(stderr, "a bad input did not fail with an error\n");
		return 1;
	}
	return 0;
}
