# Read-only Linux x86_64 inspection helper. Opens argv[1] O_RDONLY; never attaches,
# signals, pauses or writes to the target process. Input records are six uint64s:
# address, length (<=8 MiB), four exact vtable pointers. Output is address, matched
# pointer, byte count, followed by at most 512 observed bytes. No runtime libraries.
.global _start
.section .bss
.lcomm config,48
.lcomm buffer,8388608
.lcomm result,536
.lcomm fd,8
.lcomm scan_index,8
.lcomm scan_length,8
.lcomm stats,24
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
 mov %rax,fd(%rip)
next:
 xor %r8,%r8
read_config:
 xor %rax,%rax
 xor %rdi,%rdi
 lea config(%rip),%rsi
 add %r8,%rsi
 mov $48,%rdx
 sub %r8,%rdx
 syscall
 test %rax,%rax
 jz done
 js fail
 add %rax,%r8
 cmp $48,%r8
 jb read_config
 mov config+8(%rip),%rdx
 cmp $8388608,%rdx
 ja fail
 add %rdx,stats(%rip)
 mov $17,%rax
 mov fd(%rip),%rdi
 lea buffer(%rip),%rsi
 mov config(%rip),%r10
 syscall
 test %rax,%rax
 js next
 add %rax,stats+8(%rip)
 cmp $8,%rax
 jl next
 sub $8,%rax
 mov %rax,scan_length(%rip)
 movq $0,scan_index(%rip)
scan:
 mov scan_index(%rip),%r8
 lea buffer(%rip),%r9
 mov (%r9,%r8),%r12
 cmp config+16(%rip),%r12
 je hit
 cmp config+24(%rip),%r12
 je hit
 cmp config+32(%rip),%r12
 je hit
 cmp config+40(%rip),%r12
 jne advance
hit:
 incq stats+16(%rip)
 mov config(%rip),%r10
 add %r8,%r10
 mov %r10,result(%rip)
 mov %r12,result+8(%rip)
 mov $17,%rax
 mov fd(%rip),%rdi
 lea result+24(%rip),%rsi
 mov $512,%rdx
 syscall
 test %rax,%rax
 js advance
 mov %rax,result+16(%rip)
 lea 24(%rax),%rdx
 mov $1,%rax
 mov $1,%rdi
 lea result(%rip),%rsi
 syscall
advance:
 addq $8,scan_index(%rip)
 mov scan_index(%rip),%r8
 cmp scan_length(%rip),%r8
 jbe scan
 jmp next
done:
 mov $1,%rax
 mov $2,%rdi
 lea stats(%rip),%rsi
 mov $24,%rdx
 syscall
 mov $60,%rax
 xor %rdi,%rdi
 syscall
fail:
 mov $60,%rax
 mov $1,%rdi
 syscall
