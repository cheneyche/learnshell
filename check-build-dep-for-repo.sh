#!/bin/bash

debLocationList=$1
repoLocation=$2

#判断输入为非空
if [ $# != 2 ] || [ "X$1" = "X" ] || [ ! -d $2 ];then
        echo "参数输入错误! 请确认输入的参数是否正确! "
        echo "格式如下: $0 debLocationList repoLocation"
        echo "例如： $0 /mnt/cbs/pool/main/c/cdos-firewall/cdos-firewall_1.0-11+4cdos1.18_amd64.deb,/mnt/cbs/pool/main/c/cdos-firewall/cdos-firewall_1.0-11+4cdos1.18_amd64.deb /mnt/cbs/repos/cdos-3.1.010-build/latest"
        exit 1;
fi


create_tmp(){
#创建临时目录，放置本次对比的相关数据文件

	dtmp=`date +%s%N | md5sum | head -c 20`
	[[ -d /tmp/$dtmp ]] && rm -rf /tmp/$dtmp
	mkdir /tmp/$dtmp
	echo "$dtmp"
}

remove_tmp(){
#移除临时创建的目录

	dtmp=$1
	[[ -d /tmp/$dtmp ]] && rm -rf /tmp/$dtmp
}

pkg_version_from_packages(){
#对源的package文件进行提取，提取pkg和version字段，以便后续做check的依据

	local repo_location=$1
	local dtmp=$2

	#判断是否有Packages文件，如果没有报错退出
	[[ ! `find ${repo_location}/ -name "Packages"` ]] &&  echo "请输入正确的源地址，此源地址无Packages文件" && return 1

	if [ -f $dtmp/repo-pkg-version-arch ];then
		rm -rf $dtmp/repo-pkg-version-arch
	fi
	#导入所有的packages里的包名，版本号，架构到一个文件里
	for i in `find ${repo_location}/ -name "Packages"`;do
		cat $i |grep ^Filename: |awk -F'/' '{print $NF}' |awk -F'_' '{print $1"_"$2"_"$3}' >> $dtmp/repo-pkg-version-arch
	done

	#文件去重行
	cat $dtmp/repo-pkg-version-arch |sort |uniq >$dtmp/repo-pkg-version-arch.bk
	sed -i 's/\.deb$//g' $dtmp/repo-pkg-version-arch.bk
	mv $dtmp/repo-pkg-version-arch.bk $dtmp/repo-pkg-version-arch

}

pkg_version_depends_from_deb(){
#对输入的deblist做处理，整理出每个包所依赖的内容，放置到临时目录下。
	local deblist=$1
	local dtmp=$2

	#在临时目录里创建deb.list存放输入的包list，创建deb-depends目录存放每个deb的依赖关系，作为后续比对的依据之一
	[[ -f $dtmp/deb.list ]] && rm -rf $dtmp/deb.list
	[[ -d $dtmp/deb-depends ]] && rm -rf $dtmp/deb-depends
	mkdir $dtmp/deb-depends

	#写入deb.list文件及在depends目录下写入每个包的安装依赖信息
	for  i in `echo $deblist|sed 's/,/ /g'`;do
		echo $i >> $dtmp/deb.list
		debname=`echo ${i##*/}`
		dpkg-deb --show --showformat='${Depends}\n' $i |sed 's/, /\n/g' |while read line;do
		#脚本导出deb的安装依赖信息
			echo $line >> $dtmp/deb-depends/${debname}.depends
		done
	done
}

update_packages(){
#首先将待判断安装依赖关系的包信息更新到packages文件里，方可作为整个环境去判断后续的依赖关系
	local dtmp=$1
	cp $dtmp/repo-pkg-version-arch $dtmp/repo-pkg-version-arch-update

	for i in `cat $dtmp/deb.list`;do
		debname=`echo ${i##*/}`

		pkg_name=`echo $debname |awk -F'_' '{print $1}'`
		#deb包名
		pkg_version=`echo $debname |awk -F'_' '{print $2}'`
		#deb版本号
		pkg_arch=`echo $debname |awk -F'_' '{print $3}' |sed 's/\.deb$//g'`
		#deb架构
		
		#逻辑处理，判断repo-pkg-version-arch里是包含pkg_name这个包，未包含，直接追加，
		#包含则比对版本号，只有当deblist里的版本号高于时才去除repo-pkg-version-arch低版本的，写入高版本的。
		cat $dtmp/repo-pkg-version-arch-update |grep "^${pkg_name}_" |grep "_${pkg_arch}$" &>/dev/null
		if [ $? = 0 ];then
			repo_pkg_version=`cat $dtmp/repo-pkg-version-arch-update |grep "^${pkg_name}_" |grep "_${pkg_arch}$" |awk -F'_' '{print $2}'`
			dpkg --compare-versions $pkg_version gt $repo_pkg_version
			if [ $? = 0 ];then
				cat $dtmp/repo-pkg-version-arch-update |grep -v "^${pkg_name}_.*_${pkg_arch}$" >$dtmp/repo-pkg-version-arch-update.bk
				mv $dtmp/repo-pkg-version-arch-update.bk $dtmp/repo-pkg-version-arch-update
				echo ${pkg_name}_${pkg_version}_${pkg_arch} >>$dtmp/repo-pkg-version-arch-update 
			fi
		else
			echo ${pkg_name}_${pkg_version}_${pkg_arch} >>$dtmp/repo-pkg-version-arch-update
		fi

	done
}

aj_pkgname_packages(){
#传入 deb名称，临时目录地址，架构；从而去临时目录里的package里找对应架构的此包
#返回找寻结果。如果出错，会记录错误信息在对应目录的文件内
	
	local debname=$1
	local dtmp=$2
	local arch=$3
	local pkgname_depends=$4
	local or_tag=$5
	
	local pkg_name=`echo $debname |awk -F'_' '{print $1}'`
	[[ $arch = "amd64" ]] && greparch="i386" || greparch="amd64"

	cat $dtmp/repo-pkg-version-arch-update |grep -v "_${greparch}$" |grep "^${pkgname_depends}_" &>/dev/null
	if [ $? = 0 ];then
		echo "0"
	else
		if [ $or_tag = 0 ];then
			echo "${arch}架构下未发现$pkgname_depends" >>$dtmp/deb-depends/${debname}.result
		fi
		echo "1"
	fi
}

aj_check_relationship(){
#判断带有比对关系的依赖检测。传入参数见下，or_tag是一个标识符，当为|时和非|时最后处理不一样。
	local debname=$1
	local dtmp=$2
	local arch=$3
	local relationship=$4
	local rversion=$5
	local pkgname_depends=$6
	local or_tag=$7

	local pkg_name=`echo $debname |awk -F'_' '{print $1}'`
	[[ $arch = "amd64" ]] && greparch="i386" || greparch="amd64"

        cat $dtmp/repo-pkg-version-arch-update |grep -v "_${greparch}$" |grep "^${pkgname_depends}_" &>/dev/null
        if [ $? != 0 ];then
                echo "${arch}架构下未发现$pkgname_depends,而需要满足$pkgname_depends $relationship $rversion" >>$dtmp/deb-depends/${debname}.result
                echo "1"
        else
		version_packages=`cat $dtmp/repo-pkg-version-arch-update |grep -v "_${greparch}$" |grep "^${pkgname_depends}_" |awk -F'_' '{print $2}'`
		case $relationship in
			"=")
				rship="="
				;;
			">=")
				rship="ge"
				;;
			">")
				rship="gt"
				;;
			"<=")
				rship="le"
				;;
			"<")
				rship="lt"
				;;
		esac
		dpkg --compare-versions $version_packages $rship $rversion
		if [ $? = 0 ];then
                	echo "0"
		else
			if [ $or_tag = 0 ];then
				echo "${arch}架构下${pkgname_depends}版本为 $version_packages,未满足$pkgname_depends $relationship ${rversion}要求" >>$dtmp/deb-depends/${debname}.result
			fi
                	echo "1"
		fi
        fi
}

check_installation_dependencies(){
#校验deb的安装依赖
	local dtmp=$1
	tag=0
	for i in `ls $dtmp/deb-depends/*.depends`;do
		debname=`echo ${i##*/} |sed 's/\.depends$//g'`
		pkg_arch=`echo $debname |awk -F'_' '{print $3}' |sed 's/\.deb//g'`
		echo -ne "\n$debname\t 检查依赖关系:\n" 
		if [ "$pkg_arch" = "all" ];then
			check_arch="amd64 i386"
		else
			check_arch=`echo $pkg_arch`
		fi
		for j in `echo $check_arch`;do
			echo -ne "${j}架构:"
			
		     	while read line;do
				if [ "A$line" = "A" ];then break;fi
		     		echo $line | grep " " &>/dev/null
		     		if [ $? = 0 ];then
		     			#非单一内容，需判断
					echo $line |grep "|" &>/dev/null
					if [ $? != 0 ];then
						#未包含或语句
						relationship=`echo $line |awk '{print $2}' |sed 's/(//g'`
						rversion=`echo $line |awk '{print $3}' |sed 's/)//g'`
						echo $rversion |grep ":" &>/dev/null
						if [ $? = 0 ];then
							rversion=`echo $rversion |awk -F':' '{print $2}'`
						fi
						echo $line |awk '{print $1}' |grep ":" &>/dev/null
						if [ $? = 0 ];then
							#有标注特定架构
							arch_depends=`echo $line |awk '{print $1}'|awk -F':' '{print $2}'`
							if [ "A$arch_depends" = "Aany" ];then
								arch_depends=`echo $j`
							fi
							pkgname_depends=`echo $line |awk -F':' '{print $1}'`
							tag=$(($tag + `aj_check_relationship $debname $dtmp $arch_depends $relationship $rversion $pkgname_depends 0`))
						else
							#未标注特定架构
							pkgname_depends=`echo $line |awk '{print $1}'`
							tag=$(($tag + `aj_check_relationship $debname $dtmp $j $relationship $rversion $pkgname_depends 0`))
						fi
					else
						ortag=0
						#包括或语句
						echo $line |sed 's/\ |\ /\n/g'|while read or_line;do
							#把|的每一个条件单独分开,使用ortag来作为判断或语句是否成立的标示
							#当其中一个满足时，退出，ortag为0，否则都不满足，ortag为非0
							echo $or_line |grep " " &>/dev/null
							if [ $? = 0 ];then
								##非单一内容
								relationship=`echo $or_line |awk '{print $2}' |sed 's/(//g'`
		                                                rversion=`echo $or_line |awk '{print $3}' |sed 's/)//g'`
								echo $rversion |grep ":" &>/dev/null
								if [ $? = 0 ];then
									rversion=`echo $rversion |awk -F':' '{print $2}'`
								fi
								echo $or_line |awk '{print $1}' |grep ":" &>/dev/null
                        		                        if [ $? = 0 ];then
                                        		                #有标注特定架构
                                                        		arch_depends=`echo $or_line |awk '{print $1}'|awk -F':' '{print $2}'`
                                                        		pkgname_depends=`echo $or_line |awk -F':' '{print $1}'`
                                                        		ortag=$(($ortag + `aj_check_relationship $debname $dtmp $arch_depends $relationship $rversion $pkgname_depends 1`))
                                                		else
                                                        		#未标注特定架构
									pkgname_depends=`echo $or_line |awk '{print $1}'`
                                                        		ortag=$(($ortag + `aj_check_relationship $debname $dtmp $j $relationship $rversion $pkgname_depends 1`))
                                                		fi
							else
								#单一内容，无判断条件,判断是否存在此包即可
        			                                echo $or_line |grep ":" &>/dev/null
        			                                if [ $? = 0 ];then
        			                                        #有标注特定架构
        			                                        arch_depends=`echo $or_line |awk -F':' '{print $2}'`
        			                                        pkgname_depends=`echo $or_line |awk -F':' '{print $1}'`
        			                                        ortag=$(($ortag + `aj_pkgname_packages $debname $dtmp $arch_depends $pkgname_depends 1`))
        			                                else
        			                                        #未标注特定架构
        			                                        ortag=$(($ortag + `aj_pkgname_packages $debname $dtmp $j $or_line 1`))
					                        fi

							fi
							if [ $ortag = 0 ];then
								break
							fi
						done
						if [ $ortag != 0 ];then
							echo "${j}架构下未满足${line}要求" >>$dtmp/deb-depends/${debname}.result
						fi
						tag=$(($tag + $ortag))
						ortag=0
					fi
		     			
		     		else
		     			#单一内容，无判断条件,判断是否存在此包即可
		     			echo $line |grep ":" &>/dev/null
		     			if [ $? = 0 ];then
		     				#有标注特定架构
						arch_depends=`echo $line |awk -F':' '{print $2}'`
						pkgname_depends=`echo $line |awk -F':' '{print $1}'`
						tag=$(($tag + `aj_pkgname_packages $debname $dtmp $arch_depends $pkgname_depends 0`))
		     			else
		     				#未标注特定架构
						tag=$(($tag + `aj_pkgname_packages $debname $dtmp $j $line 0`))
		     			fi
		     		fi
		     	done<$i
		     	if [ $tag = 0 ];then
		     		echo -ne " 安装依赖满足。\n"
		     	else
		     		echo -ne " 依赖不满足。\n"
				cat $dtmp/deb-depends/${debname}.result
		     	fi
		done
		tag=0
	done
	
}

main(){
	#创建临时目录
	dtmp=`create_tmp`
	
	#提取package文件里包相关信息,在/tmp目录下的临时目录里会创建当前仓库的repo-pkg-version-arch
	pkg_version_from_packages $repoLocation /tmp/$dtmp/
	
	#提取deblist里每个deb的依赖信息
	pkg_version_depends_from_deb $debLocationList /tmp/$dtmp/
		
	#更新deblist包信息到repo-pkg-version-arch，会生成update文件repo-pkg-version-arch-update
	update_packages /tmp/$dtmp/	

	#检查依赖是否满足的主函数
	check_installation_dependencies /tmp/$dtmp/

	#删除临时目录
	remove_tmp $dtmp
}

main
