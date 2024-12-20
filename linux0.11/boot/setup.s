 .model tiny
 .386p

;// setup.s负责从BIOS 中获取系统数据，并将这些数据放到系统内存的适当地方。
;// 此时setup.s 和system 已经由bootsect 引导块加载到内存中。
;// 这段代码询问bios 有关内存/磁盘/其它参数，并将这些参数放到一个
;// “安全的”地方：90000-901FF，也即原来bootsect 代码块曾经在
;// 的地方，然后在被缓冲块覆盖掉之前由保护模式的system 读取。

;// 以下这些参数最好和bootsect.s 中的相同！
 INITSEG  = 9000h	;// 原来bootsect 所处的段
 SYSSEG   = 1000h	;// system 在10000(64k)处。
 SETUPSEG = 9020h	;// 本程序所在的段地址。


code segment
start:

;// ok, 整个读磁盘过程都正常，现在将光标位置保存以备今后使用。

	mov	ax,INITSEG		;// 将ds 置成INITSEG(9000)。这已经在bootsect 程序中
	mov	ds,ax			;// 设置过，但是现在是setup 程序，Linus 觉得需要再重新
						;// 设置一下。
	mov	ah,03h		;// BIOS 中断10 的读光标功能号ah = 03
	xor	bh,bh		;// 输入：bh = 页号
	int	10h			;// 返回：ch = 扫描开始线，cl = 扫描结束线，
	mov	ds:[0],dx		;// dh = 行号(00 是顶端)，dl = 列号(00 是左边)。
					;// 将光标位置信息存放在90000 处，控制台初始化时会来取。
	mov	ah,88h		;// 这3句取扩展内存的大小值（KB）。
	int	15h			;// 是调用中断15，功能号ah = 88
	mov	ds:[2],ax		;// 返回：ax = 从100000（1M）处开始的扩展内存大小(KB)。
					;// 若出错则CF 置位，ax = 出错码。

;// 下面这段用于取显示卡当前显示模式。
;// 调用BIOS 中断10，功能号ah = 0f
;// 返回：ah = 字符列数，al = 显示模式，bh = 当前显示页。
;// 90004(1 字)存放当前页，90006 显示模式，90007 字符列数。
	mov	ah,0fh
	int	10h
	mov	ds:[4],bx		;// bh = display page
	mov	ds:[6],ax		;// al = video mode, ah = window width

;// 检查显示方式（EGA/VGA）并取参数。
;// 调用BIOS 中断10，附加功能选择-取方式信息
;// 功能号：ah = 12，bl = 10
;// 返回：bh = 显示状态
;// (00 - 彩色模式，I/O 端口=3dX)
;// (01 - 单色模式，I/O 端口=3bX)
;// bl = 安装的显示内存
;// (00 - 64k, 01 - 128k, 02 - 192k, 03 = 256k)
;// cx = 显示卡特性参数(参见程序后的说明)。
	mov	ah,12h
	mov	bl,10h
	int	10h
	mov	ds:[8],ax		;// 90008 = ??
	mov	ds:[10],bx		;// 9000A = 安装的显示内存，9000B = 显示状态(彩色/单色)
	mov	ds:[12],cx		;// 9000C = 显示卡特性参数。

;// 取第一个硬盘的信息（复制硬盘参数表）。
;// 第1 个硬盘参数表的首地址竟然是中断向量41 的向量值！而第2 个硬盘
;// 参数表紧接第1 个表的后面，中断向量46 的向量值也指向这第2 个硬盘
;// 的参数表首址。表的长度是16 个字节(10)。
;// 下面两段程序分别复制BIOS 有关两个硬盘的参数表，90080 处存放第1 个
;// 硬盘的表，90090 处存放第2 个硬盘的表。
	mov	ax,0000h
	mov	ds,ax
	lds	si,ds:[4*41h]		;// 取中断向量41 的值，也即hd0 参数表的地址 ds:si
	mov	ax,INITSEG
	mov	es,ax
	mov	di,0080h		;// 传输的目的地址: 9000:0080 -> es:di
	mov	cx,10h			;// 共传输10 字节。
	rep movsb

;// Get hd1 data

	mov	ax,0000h
	mov	ds,ax
	lds	si,ds:[4*46h]		;// 取中断向量46 的值，也即hd1 参数表的地址 -> ds:si
	mov	ax,INITSEG
	mov	es,ax
	mov	di,0090h		;// 传输的目的地址: 9000:0090 -> es:di
	mov	cx,10h
	rep movsb
	

;// 检查系统是否存在第2 个硬盘，如果不存在则第2 个表清零。
;// 利用BIOS 中断调用13 的取盘类型功能。
;// 功能号ah = 15；
;// 输入：dl = 驱动器号（8X 是硬盘：80 指第1 个硬盘，81 第2 个硬盘）
;// 输出：ah = 类型码；00 --没有这个盘，CF 置位； 01 --是软驱，没有change-line 支持；
;//  02--是软驱(或其它可移动设备)，有change-line 支持； 03 --是硬盘。
	mov	ax,1500h
	mov	dl,81h
	int	13h
	jc	no_disk1
	cmp	ah,3			;// 是硬盘吗？(类型= 3 ？)。
	je	is_disk1
no_disk1:
	mov	ax,INITSEG		;// 第2个硬盘不存在，则对第2个硬盘表清零。
	mov	es,ax
	mov	di,0090h
	mov	cx,10h
	mov	ax,00h
	rep stosb
	
is_disk1:

;// 从这里开始我们要保护模式方面的工作了。

	cli			;// 此时不允许中断。 ;//

;// 首先我们将system 模块移到正确的位置。
;// bootsect 引导程序是将system 模块读入到从10000（64k）开始的位置。由于当时假设
;// system 模块最大长度不会超过80000（512k），也即其末端不会超过内存地址90000，
;// 所以bootsect 会将自己移动到90000 开始的地方，并把setup 加载到它的后面。
;// 下面这段程序的用途是再把整个system 模块移动到00000 位置，即把从10000 到8ffff
;// 的内存数据块(512k)，整块地向内存低端移动了10000（64k）的位置。

	mov	ax,0000h
	cld			;// 'direction'=0, movs moves forward
do_move:
	mov	es,ax		;// es:di -> 目的地址(初始为0000:0)
	add	ax,1000h
	cmp	ax,9000h	;// 已经把从8000 段开始的64k 代码移动完？
	jz	end_move
	mov	ds,ax		;// ds:si -> 源地址(初始为1000:0)
	sub	di,di
	sub	si,si
	mov cx,8000h	;// 移动8000 字（64k 字节）。
	rep movsw
	jmp	do_move

;// 此后，我们加载段描述符。
;// 从这里开始会遇到32 位保护模式的操作，因此需要Intel 32 位保护模式编程方面的知识了,
;// 有关这方面的信息请查阅列表后的简单介绍或附录中的详细说明。这里仅作概要说明。
;//
;// lidt 指令用于加载中断描述符表(idt)寄存器，它的操作数是6 个字节，0-1 字节是描述符表的
;// 长度值(字节)；2-5 字节是描述符表的32 位线性基地址（首地址），其形式参见下面
;// 219-220 行和223-224 行的说明。中断描述符表中的每一个表项（8 字节）指出发生中断时
;// 需要调用的代码的信息，与中断向量有些相似，但要包含更多的信息。
;//
;// lgdt 指令用于加载全局描述符表(gdt)寄存器，其操作数格式与lidt 指令的相同。全局描述符
;// 表中的每个描述符项(8 字节)描述了保护模式下数据和代码段（块）的信息。其中包括段的
;// 最大长度限制(16 位)、段的线性基址（32 位）、段的特权级、段是否在内存、读写许可以及
;// 其它一些保护模式运行的标志。参见后面205-216 行。
;//

end_move:
	mov	ax,SETUPSEG		;// right, forgot this at first. didn't work :-)
	mov	ds,ax			;// ds 指向本程序(setup)段。因为上面操作改变了ds的值。

	lidt fword ptr idt_48			;// 加载中断描述符表(idt)寄存器，idt_48 是6 字节操作数的位置
						;// 前2 字节表示idt 表的限长，后4 字节表示idt 表所处的基地址。

	lgdt fword ptr gdt_48			;// 加载全局描述符表(gdt)寄存器，gdt_48 是6 字节操作数的位置

;// 以上的操作很简单，现在我们开启A20 地址线。

	call empty_8042		;// 等待输入缓冲器空。
						;// 只有当输入缓冲器为空时才可以对其进行写命令。
	mov	al,0D1h			;// D1 命令码-表示要写数据到8042 的P2 端口。P2 端
	out	64h,al			;// 口的位1 用于A20 线的选通。数据要写到60 口。

	call empty_8042		;// 等待输入缓冲器空，看命令是否被接受。
	mov	al,0DFh			;// A20 on 选通A20 地址线的参数。
	out	60h,al
	call empty_8042		;// 输入缓冲器为空，则表示A20 线已经选通。

;// 希望以上一切正常。现在我们必须重新对中断进行编程 
;// 我们将它们放在正好处于intel 保留的硬件中断后面，在int 20-2F。
;// 在那里它们不会引起冲突。不幸的是IBM 在原PC 机中搞糟了，以后也没有纠正过来。
;// PC 机的bios 将中断放在了08-0f，这些中断也被用于内部硬件中断。
;// 所以我们就必须重新对8259 中断控制器进行编程，这一点都没劲。

	mov	al,11h		;// 11 表示初始化命令开始，是ICW1 命令字，表示边
					;// 沿触发、多片8259 级连、最后要发送ICW4 命令字。
	out	20h,al		;// 发送到8259A 主芯片。
	dw	00ebh,00ebh		;// jmp $+2, jmp $+2  $ 表示当前指令的地址，
								;// 两条跳转指令，跳到下一条指令，起延时作用。
	out	0A0h,al		;// and to 8259A-2 ;// 再发送到8259A 从芯片。
	dw	00ebh,00ebh
	mov	al,20h		;// start of hardware int's (20)
	out	21h,al		;// 送主芯片ICW2 命令字，起始中断号，要送奇地址。
	dw	00ebh,00ebh
	mov	al,28h		;// start of hardware int's 2 (28)
	out	0A1h,al		;// 送从芯片ICW2 命令字，从芯片的起始中断号。
	dw	00ebh,00ebh
	mov	al,04h		;// 8259-1 is master
	out	21h,al		;// 送主芯片ICW3 命令字，主芯片的IR2 连从芯片INT。
	dw	00ebh,00ebh	;// 参见代码列表后的说明。
	mov	al,02h		;// 8259-2 is slave
	out	0A1h,al		;// 送从芯片ICW3 命令字，表示从芯片的INT 连到主芯
						;// 片的IR2 引脚上。
	dw	00ebh,00ebh
	mov	al,01h		;// 8086 mode for both
	out	21h,al		;// 送主芯片ICW4 命令字。8086 模式；普通EOI 方式，
						;// 需发送指令来复位。初始化结束，芯片就绪。
	dw	00ebh,00ebh
	out	0A1h,al		;// 送从芯片ICW4 命令字，内容同上。
	dw	00ebh,00ebh
	mov	al,0FFh		;// mask off all interrupts for now
	out	21h,al		;// 屏蔽主芯片所有中断请求。
	dw	00ebh,00ebh
	out	0A1h,al		;// 屏蔽从芯片所有中断请求。

;// 哼，上面这段当然没劲 ，希望这样能工作，而且我们也不再需要乏味的BIOS 了（除了
;// 初始的加载.。BIOS 子程序要求很多不必要的数据，而且它一点都没趣。那是“真正”的
;// 程序员所做的事。

;// 这里设置进入32 位保护模式运行。首先加载机器状态字(lmsw - Load Machine Status Word)，
;// 也称控制寄存器CR0，其比特位0 置1 将导致CPU 工作在保护模式。  80286 

	mov	ax,0001h	;// 保护模式比特位(PE)。
	lmsw ax			;// 就这样加载机器状态字
	jmp 8:0  		;// 跳转至cs 段8，偏移0 处。执行system 中的代码   刷新流水线  cpu流水线  预先取指令  熔断漏洞
	db 0eah
	dw 0
	dw 8
;// 我们已经将system 模块移动到00000 开始的地方，所以这里的偏移地址是0。这里的段值
;// 的8 已经是保护模式下的段选择符了，用于选择描述符表和描述符表项以及所要求的特权级。
;// 段选择符长度为16 位（2 字节）；位0-1 表示请求的特权级0-3，linux 操作系统只用
;// 到两级：0 级（系统级）和3 级（用户级）；位2 用于选择全局描述符表(0)还是局部描
;// 述符表(1)；位3-15 是描述符表项的索引，指出选择第几项描述符。所以段选择符
;// 8(00000,0000,0000,1000)表示请求特权级0、使用全局描述符表中的第1 项，该项指出
;// 代码的基地址是0，因此这里的跳转指令就会去执行system 中的代码。


;// 下面这个子程序检查键盘命令队列是否为空。这里不使用超时方法- 如果这里死机，
;// 则说明PC 机有问题，我们就没有办法再处理下去了。
;// 只有当输入缓冲器为空时（状态寄存器位2 = 0）才可以对其进行写命令。
empty_8042:
	dw 00ebh,00ebh	;// jmp $+2, jmp $+2 $ 表示当前指令的地址
						;// 这是两个跳转指令的机器码(跳转到下一句)，相当于延时空操作。
	in	al,64h			;// 读AT 键盘控制器状态寄存器。
	test al,2			;// 测试位2，输入缓冲器满？
	jnz	empty_8042		;// yes - loop
	ret

;// 全局描述符表开始处。描述符表由多个8 字节长的描述符项组成。
;// 这里给出了3 个描述符项。第1 项无用，但须存在。第2 项是系统代码段
;// 描述符（208-211 行），第3 项是系统数据段描述符(213-216 行)。每个描述符的具体
;// 含义参见列表后说明。
gdt:
	dw	0,0,0,0		;// 第1 个描述符，不用。
;// 这里在gdt 表中的偏移量为08，当加载代码段寄存器(段选择符)时，使用的是这个偏移值。
	dw	07FFh		;// 8Mb - limit=2047 (2048*4096=8Mb)
	dw	0000h		;// base address=0
	dw	9A00h		;// code read/exec
	dw	00C0h		;// granularity=4096, 386
;// 这里在gdt 表中的偏移量是10，当加载数据段寄存器(如ds 等)时，使用的是这个偏移值。
	dw	07FFh		;// 8Mb - limit=2047 (2048*4096=8Mb)
	dw	0000h		;// base address=0
	dw	9200h		;// data read/write
	dw	00C0h		;// granularity=4096, 386

idt_48:
	dw	0			;// idt limit=0
	dw	0,0			;// idt base=0L

gdt_48:
	dw	800h		;// 全局表长度为2k 字节，因为每8 字节组成一个段描述符项
						;// 所以表中共可有256 项。
	dw	512+gdt,9h	;// 4 个字节构成的内存线性地址：0009<<16 + 0200+gdt
						;// 也即90200 + gdt(即在本程序段中的偏移地址，205 行)。
	
code ends
end