# Bounded read-only bulk reader: argv[1] O_RDONLY; no attach, signals or target writes.
# Input uint64 address,length; output same header and exact bytes; max128KiB/read.
.global _start
.section .bss
.lcomm record,16
.lcomm output,131088
.lcomm target_fd,8
.section .text
_start:
 mov 16(%rsp),%rdi
 test %rdi,%rdi
 jz fail
 mov $2,%rax
 xor %rsi,%rsi
 xor %rdx,%rdx
 syscall
 test %rax,%rax
 js fail
 mov %rax,target_fd(%rip)
next:
 xor %r8,%r8
input:
 xor %rax,%rax
 xor %rdi,%rdi
 lea record(%rip),%rsi
 add %r8,%rsi
 mov $16,%rdx
 sub %r8,%rdx
 syscall
 test %rax,%rax
 js fail
 jz eof
 add %rax,%r8
 cmp $16,%r8
 jb input
 mov record+8(%rip),%rdx
 test %rdx,%rdx
 jz fail
 cmp $131072,%rdx
 ja fail
 mov record(%rip),%r10
 cmp $65536,%r10
 jb fail
 mov $17,%rax
 mov target_fd(%rip),%rdi
 lea output+16(%rip),%rsi
 syscall
 cmp record+8(%rip),%rax
 jne fail
 mov record(%rip),%r12
 mov %r12,output(%rip)
 mov %rax,output+8(%rip)
 lea 16(%rax),%r13
 xor %r8,%r8
write:
 mov $1,%rax
 mov $1,%rdi
 lea output(%rip),%rsi
 add %r8,%rsi
 mov %r13,%rdx
 sub %r8,%rdx
 syscall
 test %rax,%rax
 jle fail
 add %rax,%r8
 cmp %r13,%r8
 jb write
 jmp next
eof:
 test %r8,%r8
 jnz fail
 mov $60,%rax
 xor %rdi,%rdi
 syscall
fail:
 mov $60,%rax
 mov $1,%rdi
 syscall
