/* THROWAWAY PROTOTYPE - issue #398 section B libelf feasibility spike.
 * Not wired into the build. Standalone test of the decompress/patch/
 * recompress round-trip via elfutils' libelf, evaluated against a real
 * SHF_COMPRESSED .debug_info/.debug_str/.debug_line_str section.
 *
 * Reuses replace_string()'s exact semantics from src/fix_debug_info.c
 * (same-length replace only) -- copied here rather than #include'd since
 * the original is `static` and this is a standalone experiment, not a
 * real integration.
 *
 * Build (inside ghcr.io/wiki-mod/distcc-ng-buildtools):
 *   gcc -Wall -Wextra -o libelf_fix_prototype libelf_fix_prototype.c -lelf
 *
 * Usage: libelf_fix_prototype <path> <client-path> <server-path>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <assert.h>
#include <gelf.h>
#include <libelf.h>

/* Copied verbatim from src/fix_debug_info.c's replace_string(): same-length
 * substring replace only, no structure awareness. */
static int replace_string(void *base, size_t size,
                           const char *search, const char *replace) {
  char *start = (char *) base;
  char *end = (char *) base + size;
  int count = 0;
  char *p;
  size_t search_len = strlen(search);
  size_t replace_len = strlen(replace);

  assert(replace_len == search_len);

  if (size < search_len + 1)
    return 0;
  for (p = start; p < end - search_len - 1; p++) {
    if (memcmp(p, search, search_len) == 0) {
      memcpy(p, replace, replace_len);
      count++;
    }
  }
  return count;
}

/* Finds a section by name via libelf's own section-header-string-table
 * lookup (elf_strptr), instead of fix_debug_info.c's raw Elf32/64_Shdr
 * array walk -- the libelf-native equivalent of FindElfSection(). */
static Elf_Scn *find_section_by_name(Elf *elf, const char *name) {
  size_t shstrndx;
  Elf_Scn *scn = NULL;

  if (elf_getshdrstrndx(elf, &shstrndx) != 0) {
    fprintf(stderr, "elf_getshdrstrndx failed: %s\n", elf_errmsg(-1));
    return NULL;
  }

  while ((scn = elf_nextscn(elf, scn)) != NULL) {
    GElf_Shdr shdr;
    if (gelf_getshdr(scn, &shdr) != &shdr) {
      fprintf(stderr, "gelf_getshdr failed: %s\n", elf_errmsg(-1));
      continue;
    }
    const char *sname = elf_strptr(elf, shstrndx, shdr.sh_name);
    if (sname != NULL && strcmp(sname, name) == 0) {
      return scn;
    }
  }
  return NULL;
}

/* Handles one section: decompress if needed, replace, recompress if it
 * was compressed to start with. Returns the number of replacements made
 * (0 is not an error -- the string may legitimately not be present in
 * this particular section), or -1 on a real libelf error. */
static int fix_one_section(Elf *elf, const char *section_name,
                            const char *search, const char *replace) {
  Elf_Scn *scn = find_section_by_name(elf, section_name);
  if (scn == NULL) {
    printf("  [%s] not present, skipping\n", section_name);
    return 0;
  }

  GElf_Shdr shdr;
  if (gelf_getshdr(scn, &shdr) != &shdr) {
    fprintf(stderr, "  [%s] gelf_getshdr failed: %s\n", section_name, elf_errmsg(-1));
    return -1;
  }

  int was_compressed = (shdr.sh_flags & SHF_COMPRESSED) != 0;
  if (was_compressed) {
    printf("  [%s] SHF_COMPRESSED set, decompressing via elf_compress(scn, 0, 0)\n",
           section_name);
    int rc = elf_compress(scn, 0, 0);
    if (rc < 0) {
      fprintf(stderr, "  [%s] elf_compress (decompress) failed: %s\n",
              section_name, elf_errmsg(-1));
      return -1;
    }
    /* "All previous returned Shdrs and Elf_Data buffers are invalidated
     * by this call" per libelf.h -- must not reuse the pre-decompress
     * scn/shdr/data pointers here. scn itself (the Elf_Scn*) stays valid,
     * only the Shdr/Elf_Data content it points to is invalidated. */
  }

  Elf_Data *data = elf_getdata(scn, NULL);
  if (data == NULL) {
    fprintf(stderr, "  [%s] elf_getdata failed: %s\n", section_name, elf_errmsg(-1));
    return -1;
  }

  int count = replace_string(data->d_buf, data->d_size, search, replace);
  printf("  [%s] replaced %d occurrence(s) of the server path\n", section_name, count);

  if (count > 0) {
    /* elf_compress's own doc: "doesn't mark the section as dirty ...
     * has to be flagged ELF_F_DIRTY" -- same requirement applies to a
     * plain in-place Elf_Data mutation like this one. */
    elf_flagdata(data, ELF_C_SET, ELF_F_DIRTY);
  }

  if (was_compressed) {
    printf("  [%s] recompressing via elf_compress(scn, ELFCOMPRESS_ZLIB, 0)\n",
           section_name);
    int rc = elf_compress(scn, ELFCOMPRESS_ZLIB, 0);
    if (rc < 0) {
      fprintf(stderr, "  [%s] elf_compress (recompress) failed: %s\n",
              section_name, elf_errmsg(-1));
      return -1;
    }
    if (rc == 0) {
      /* Per libelf.h: "If (not forced) compression is requested and the
       * data section would not actually reduce in size, the section is
       * not actually compressed and zero is returned." Force it anyway,
       * so the section shape (compressed/not) is preserved regardless of
       * whether the edited content happens to compress as well as the
       * original -- a same-length edit could plausibly compress slightly
       * worse and cross that threshold. */
      printf("  [%s] recompression would not shrink the section, forcing with ELF_CHF_FORCE\n",
             section_name);
      rc = elf_compress(scn, ELFCOMPRESS_ZLIB, ELF_CHF_FORCE);
      if (rc < 0) {
        fprintf(stderr, "  [%s] forced elf_compress (recompress) failed: %s\n",
                section_name, elf_errmsg(-1));
        return -1;
      }
    }
  }

  return count;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "Usage: %s <path> <client-path> <server-path>\n", argv[0]);
    return 1;
  }
  const char *path = argv[1];
  const char *client_path = argv[2];
  const char *server_path = argv[3];

  if (elf_version(EV_CURRENT) == EV_NONE) {
    fprintf(stderr, "elf_version failed: %s\n", elf_errmsg(-1));
    return 1;
  }

  /* Same-length constraint as the real dcc_fix_debug_info(): pad the
   * client path with trailing slashes to match the server path's length. */
  size_t client_len = strlen(client_path);
  size_t server_len = strlen(server_path);
  if (client_len > server_len) {
    fprintf(stderr, "client path longer than server path, not supported by this prototype\n");
    return 1;
  }
  char *padded_client = malloc(server_len + 1);
  strcpy(padded_client, client_path);
  while (client_len < server_len) {
    padded_client[client_len++] = '/';
  }
  padded_client[client_len] = '\0';
  printf("padded client path: %s\n", padded_client);

  int fd = open(path, O_RDWR);
  if (fd < 0) {
    perror("open");
    return 1;
  }

  Elf *elf = elf_begin(fd, ELF_C_RDWR, NULL);
  if (elf == NULL) {
    fprintf(stderr, "elf_begin failed: %s\n", elf_errmsg(-1));
    return 1;
  }

  if (elf_kind(elf) != ELF_K_ELF) {
    fprintf(stderr, "not an ELF file\n");
    return 1;
  }

  const char *sections[] = {".debug_info", ".debug_str", ".debug_line_str"};
  int total = 0;
  for (size_t i = 0; i < sizeof(sections) / sizeof(sections[0]); i++) {
    int count = fix_one_section(elf, sections[i], server_path, padded_client);
    if (count < 0) {
      fprintf(stderr, "fatal error processing %s, aborting without writing\n", sections[i]);
      elf_end(elf);
      close(fd);
      return 1;
    }
    total += count;
  }

  printf("total replacements: %d\n", total);

  if (elf_update(elf, ELF_C_WRITE) < 0) {
    fprintf(stderr, "elf_update failed: %s\n", elf_errmsg(-1));
    elf_end(elf);
    close(fd);
    return 1;
  }

  elf_end(elf);
  close(fd);
  printf("wrote %s successfully\n", path);
  return 0;
}
