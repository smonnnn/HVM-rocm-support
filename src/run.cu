#include "hvm.cu"

// Readback: λ-Encoded Ctr
struct Ctr {
  u32  tag;
  u32  args_len;
  Port args_buf[16];
};

// Readback: λ-Encoded Str (UTF-32)
// FIXME: this is actually ASCII :|
// FIXME: remove len limit
struct Str {
  u32  text_len;
  char text_buf[256];
};

// IO Magic Number
#define IO_MAGIC_0 0xD0CA11
#define IO_MAGIC_1 0xFF1FF1

// IO Tags
#define IO_DONE 0
#define IO_CALL 1

// List Type
#define LIST_NIL  0
#define LIST_CONS 1

// Readback
// --------

// Reads back a λ-Encoded constructor from device to host.
// Encoding: λt ((((t TAG) arg0) arg1) ...)
Ctr gnet_readback_ctr(GNet* gnet, Port port) {
  Ctr ctr;
  ctr.tag = -1;
  ctr.args_len = 0;

  // Loads root lambda
  Port lam_port = gnet_expand(gnet, port);
  if (get_tag(lam_port) != CON) return ctr;
  Pair lam_node = gnet_node_load(gnet, get_val(lam_port));

  // Loads first application
  Port app_port = gnet_expand(gnet, get_fst(lam_node));
  if (get_tag(app_port) != CON) return ctr;
  Pair app_node = gnet_node_load(gnet, get_val(app_port));

  // Loads first argument (as the tag)
  Port arg_port = gnet_expand(gnet, get_fst(app_node));
  if (get_tag(arg_port) != NUM) return ctr;
  ctr.tag = get_u24(get_val(arg_port));

  // Loads remaining arguments
  while (TRUE) {
    app_port = gnet_expand(gnet, get_snd(app_node));
    if (get_tag(app_port) != CON) break;
    app_node = gnet_node_load(gnet, get_val(app_port));
    arg_port = gnet_expand(gnet, get_fst(app_node));
    ctr.args_buf[ctr.args_len++] = arg_port;
  }

  return ctr;
}

// Reads back a UTF-32 (truncated to 24 bits) string.
// Since unicode scalars can fit in 21 bits, HVM's u24
// integers can contain any unicode scalar value.
// Encoding:
// - λt (t NIL)
// - λt (((t CONS) head) tail)
Str gnet_readback_str(GNet* gnet, Port port) {
  // Result
  Str str;
  str.text_len = 0;

  // Readback loop
  while (TRUE) {
    // Normalizes the net
    gnet_normalize(gnet);

    // Reads the λ-Encoded Ctr
    Ctr ctr = gnet_readback_ctr(gnet, gnet_peek(gnet, port));

    // Reads string layer
    switch (ctr.tag) {
      case LIST_NIL: {
        break;
      }
      case LIST_CONS: {
        if (ctr.args_len != 2) break;
        if (get_tag(ctr.args_buf[0]) != NUM) break;
        if (str.text_len >= 256) { printf("ERROR: for now, HVM can only readback strings of length <256."); break; }

        str.text_buf[str.text_len++] = get_u24(get_val(ctr.args_buf[0]));
        gnet_boot_redex(gnet, new_pair(ctr.args_buf[1], ROOT));
        port = ROOT;
        continue;
      }
    }
    break;
  }

  str.text_buf[str.text_len] = '\0';

  return str;
}

/// Returns a λ-Encoded Ctr for a NIL: λt (t NIL)
/// Should only be called within `inject_str`, as a previous call
/// to `get_resources` is expected.
__device__ Port inject_nil(Net* net, TM* tm) {
  u32 v1 = tm->vloc[0];

  u32 n1 = tm->nloc[0];
  u32 n2 = tm->nloc[1];

  vars_create(net, v1, NONE);
  Port var = new_port(VAR, v1);

  node_create(net, n1, new_pair(new_port(NUM, new_u24(LIST_NIL)), var));
  node_create(net, n2, new_pair(new_port(CON, n1), var));

  return new_port(CON, n2);
}

/// Returns a λ-Encoded Ctr for a CONS: λt (((t CONS) head) tail)
/// Should only be called within `inject_str`, as a previous call
/// to `get_resources` is expected.
/// The `char_idx` parameter is used to offset the vloc and nloc
/// allocations, otherwise they would conflict with each other on
/// subsequent calls.
__device__ Port inject_cons(Net* net, TM* tm, Port head, Port tail, u32 char_idx) {
  u32 v1 = tm->vloc[1 + char_idx];

  u32 n1 = tm->nloc[2 + char_idx * 4 + 0];
  u32 n2 = tm->nloc[2 + char_idx * 4 + 1];
  u32 n3 = tm->nloc[2 + char_idx * 4 + 2];
  u32 n4 = tm->nloc[2 + char_idx * 4 + 3];

  vars_create(net, v1, NONE);
  Port var = new_port(VAR, v1);

  node_create(net, n1, new_pair(tail, var));
  node_create(net, n2, new_pair(head, new_port(CON, n1)));
  node_create(net, n3, new_pair(new_port(NUM, new_u24(LIST_CONS)), new_port(CON, n2)));
  node_create(net, n4, new_pair(new_port(CON, n3), var));

  return new_port(CON, n4);
}

// Converts a UTF-32 (truncated to 24 bits) string to a Port.
// Since unicode scalars can fit in 21 bits, HVM's u24
// integers can contain any unicode scalar value.
// Encoding:
// - λt (t NIL)
// - λt (((t CONS) head) tail)
__device__ Port inject_str(Net* net, TM* tm, Str *str) {
  // Allocate all resources up front:
  // - NIL needs  2 nodes & 1 var
  // - CONS needs 4 nodes & 1 var
  u32 len = str->text_len;
  if (!get_resources(net, tm, 0, 2 + 4 * len, 1 + len)) {
    printf("inject_str: failed to get resources\n");
    return new_port(ERA, 0);
  }

  Port port = inject_nil(net, tm);

  for (u32 i = 0; i < len; i++) {
    Port chr = new_port(NUM, new_u24(str->text_buf[len - i - 1]));
    port = inject_cons(net, tm, chr, port, i);
  }

  return port;
}

__global__ void make_str_port(GNet* gnet, Str *str, Port* ret) {
  if (GID() == 0) {
    TM tm;
    Net net = vnet_new(gnet, NULL, gnet->turn);
    *ret = inject_str(&net, &tm, str);
  }
}

// Converts a UTF-32 (truncated to 24 bits) string to a Port.
// Since unicode scalars can fit in 21 bits, HVM's u24
// integers can contain any unicode scalar value.
// Encoding:
// - λt (t NIL)
// - λt (((t CONS) head) tail)
Port gnet_inject_str(GNet* gnet, Str *str) {
  Port* d_ret;
  cudaMalloc(&d_ret, sizeof(Port));

  Str* cu_str;
  cudaMalloc(&cu_str, sizeof(Str));
  cudaMemcpy(cu_str, str, sizeof(Str), cudaMemcpyHostToDevice);

  make_str_port<<<1,1>>>(gnet, cu_str, d_ret);

  Port ret;
  cudaMemcpy(&ret, d_ret, sizeof(Port), cudaMemcpyDeviceToHost);
  cudaFree(d_ret);

  return ret;
}

// Primitive IO Fns
// -----------------

// Open file pointers. Indices into this array
// are used as "file descriptors".
// Indices 0 1 and 2 are reserved.
// - 0 -> stdin
// - 1 -> stdout
// - 2 -> stderr
static FILE* FILE_POINTERS[256];

// Converts a NUM port (file descriptor) to file pointer.
FILE* readback_file(Port port) {
  if (get_tag(port) != NUM) {
    fprintf(stderr, "non-num where file descriptor was expected: %i\n", get_tag(port));
    return NULL;
  }

  u32 idx = get_u24(get_val(port));

  if (idx == 0) return stdin;
  if (idx == 1) return stdout;
  if (idx == 2) return stderr;

  FILE* fp = FILE_POINTERS[idx];
  if (fp == NULL) {
    fprintf(stderr, "invalid file descriptor\n");
    return NULL;
  }

  return fp;
}

// Reads a single char from `argm`.
Port io_read_char(GNet* gnet, Port argm) {
  FILE* fp = readback_file(gnet_peek(gnet, argm));
  if (fp == NULL) {
    return new_port(ERA, 0);
  }

  /// Read a string.
  Str str;

  str.text_buf[0] = fgetc(fp);
  str.text_buf[1] = 0;
  str.text_len = 1;

  return gnet_inject_str(gnet, &str);
}

// Reads from `argm` at most 255 characters or until a newline is seen.
Port io_read_line(GNet* gnet, Port argm) {
  FILE* fp = readback_file(gnet_peek(gnet, argm));
  if (fp == NULL) {
    fprintf(stderr, "io_read_line: invalid file descriptor\n");
    return new_port(ERA, 0);
  }

  /// Read a string.
  Str str;

  if (fgets(str.text_buf, sizeof(str.text_buf), fp) == NULL) {
    fprintf(stderr, "io_read_line: failed to read\n");
  }
  str.text_len = strlen(str.text_buf);

  // Strip any trailing newline.
  if (str.text_len > 0 && str.text_buf[str.text_len - 1] == '\n') {
    str.text_buf[str.text_len] = 0;
    str.text_len--;
  }

  // Convert it to a port.
  return gnet_inject_str(gnet, &str);
}

// Opens a file with the provided mode.
// `argm` is a tuple (CON node) of the
// file name and mode as strings.
Port io_open_file(GNet* gnet, Port argm) {
  if (get_tag(gnet_peek(gnet, argm)) != CON) {
    fprintf(stderr, "io_open_file: expected tuple\n");
    return new_port(ERA, 0);
  }

  Pair args = gnet_node_load(gnet, get_val(argm));
  Str name = gnet_readback_str(gnet, get_fst(args));
  Str mode = gnet_readback_str(gnet, get_snd(args));

  for (u32 fd = 3; fd < sizeof(FILE_POINTERS); fd++) {
    if (FILE_POINTERS[fd] == NULL) {
      FILE_POINTERS[fd] = fopen(name.text_buf, mode.text_buf);
      return new_port(NUM, new_u24(fd));
    }
  }

  fprintf(stderr, "io_open_file: too many open files\n");

  return new_port(ERA, 0);
}

// Closes a file, reclaiming the file descriptor.
Port io_close_file(GNet* gnet, Port argm) {
  FILE* fp = readback_file(gnet_peek(gnet, argm));
  if (fp == NULL) {
    fprintf(stderr, "io_close_file: failed to close\n");
    return new_port(ERA, 0);
  }

  int err = fclose(fp) != 0;
  if (err != 0) {
    fprintf(stderr, "io_close_file: failed to close: %i\n", err);
    return new_port(ERA, 0);
  }

  FILE_POINTERS[get_u24(get_val(argm))] = NULL;

  return new_port(ERA, 0);
}

// Writes a string to a file.
// `argm` is a tuple (CON node) of the
// file descriptor and string to write.
Port io_write(GNet* gnet, Port argm) {
  if (get_tag(gnet_peek(gnet, argm)) != CON) {
    fprintf(stderr, "io_write: expected tuple, but got %u", get_tag(gnet_peek(gnet, argm)));
    return new_port(ERA, 0);
  }

  Pair args = gnet_node_load(gnet, get_val(argm));
  FILE* fp = readback_file(gnet_peek(gnet, get_fst(args)));
  Str str = gnet_readback_str(gnet, get_snd(args));

  if (fp == NULL) {
    fprintf(stderr, "io_write: invalid file descriptor\n");
    return new_port(ERA, 0);
  }

  if (fputs(str.text_buf, fp) == EOF) {
    fprintf(stderr, "io_write: failed to write\n");
  }

  return new_port(ERA, 0);
}

// Returns the current time as a tuple of the high
// and low 24 bits of a 48-bit nanosecond timestamp.
Port io_get_time(GNet* gnet, Port argm) {
  // Get the current time in nanoseconds
  u64 time_ns = time64();
  // Encode the time as a 64-bit unsigned integer
  u32 time_hi = (u32)(time_ns >> 24) & 0xFFFFFFF;
  u32 time_lo = (u32)(time_ns & 0xFFFFFFF);
  // Return the encoded time
  return gnet_make_node(gnet, CON, new_port(NUM, new_u24(time_hi)), new_port(NUM, new_u24(time_lo)));
}

// Sleeps.
// `argm` is a tuple (CON node) of the high and low
// 24 bits for a 48-bit duration in nanoseconds.
Port io_sleep(GNet* gnet, Port argm) {
  // Get the sleep duration node
  Pair dur_node = gnet_node_load(gnet, get_val(argm));
  // Get the high and low 24-bit parts of the duration
  u32 dur_hi = get_u24(get_val(get_fst(dur_node)));
  u32 dur_lo = get_u24(get_val(get_snd(dur_node)));
  // Combine into a 48-bit duration in nanoseconds
  u64 dur_ns = (((u64)dur_hi) << 24) | dur_lo;
  // Sleep for the specified duration
  struct timespec ts;
  ts.tv_sec = dur_ns / 1000000000;
  ts.tv_nsec = dur_ns % 1000000000;
  nanosleep(&ts, NULL);
  // Return an eraser
  return new_port(ERA, 0);
}

void book_init(Book* book) {
  book->ffns_buf[book->ffns_len++] = (FFn){"READ_CHAR", io_read_char};
  book->ffns_buf[book->ffns_len++] = (FFn){"READ_LINE", io_read_line};
  book->ffns_buf[book->ffns_len++] = (FFn){"OPEN_FILE", io_open_file};
  book->ffns_buf[book->ffns_len++] = (FFn){"CLOSE_FILE", io_close_file};
  book->ffns_buf[book->ffns_len++] = (FFn){"WRITE", io_write};
  book->ffns_buf[book->ffns_len++] = (FFn){"GET_TIME", io_get_time};
  book->ffns_buf[book->ffns_len++] = (FFn){"SLEEP", io_sleep};

  cudaMemcpyToSymbol(BOOK, book, sizeof(Book));
}

// Monadic IO Evaluator
// ---------------------

// Runs an IO computation.
void do_run_io(GNet* gnet, Book* book, Port port) {
   book_init(book);

  // IO loop
  while (TRUE) {
    // Normalizes the net
    gnet_normalize(gnet);

    // Reads the λ-Encoded Ctr
    Ctr ctr = gnet_readback_ctr(gnet, gnet_peek(gnet, port));

    // Checks if IO Magic Number is a CON
    if (get_tag(ctr.args_buf[0]) != CON) {
      break;
    }

    // Checks the IO Magic Number
    Pair io_magic = gnet_node_load(gnet, get_val(ctr.args_buf[0]));
    //printf("%08x %08x\n", get_u24(get_val(get_fst(io_magic))), get_u24(get_val(get_snd(io_magic))));
    if (get_val(get_fst(io_magic)) != new_u24(IO_MAGIC_0) || get_val(get_snd(io_magic)) != new_u24(IO_MAGIC_1)) {
      break;
    }

    switch (ctr.tag) {
      case IO_CALL: {
        Str  func = gnet_readback_str(gnet, ctr.args_buf[1]);
        FFn* ffn  = NULL;
        // FIXME: optimize this linear search
        for (u32 fid = 0; fid < book->ffns_len; ++fid) {
          if (strcmp(func.text_buf, book->ffns_buf[fid].name) == 0) {
            ffn = &book->ffns_buf[fid];
            break;
          }
        }
        if (ffn == NULL) {
          printf("FOUND NOTHING when looking for %s\n", func.text_buf);
          break;
        }

        Port argm = ctr.args_buf[2];
        Port cont = ctr.args_buf[3];
        Port ret  = ffn->func(gnet, argm);

        Port p = gnet_make_node(gnet, CON, ret, ROOT);
        gnet_boot_redex(gnet, new_pair(p, cont));
        port = ROOT;
        continue;
      }
      case IO_DONE: {
        printf("DONE\n");
        break;
      }
    }
    break;
  }
}
