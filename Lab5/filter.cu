// Lab 5, image filters with CUDA.

// Compile with a command-line similar to Lab 4:
// nvcc filter.cu -c -arch=sm_30 -o filter.o
// g++ filter.o milli.c readppm.c -lGL -lm -lcuda -lcudart -L/usr/local/cuda/lib -lglut -o filter
// or (multicore lab)
// nvcc filter.cu -c -arch=sm_20 -o filter.o
// g++ filter.o milli.c readppm.c -lGL -lm -lcuda -L/usr/local/cuda/lib64 -lcudart -lglut -o filter

// 2017-11-27: Early pre-release, dubbed "beta".
// 2017-12-03: First official version! Brand new lab 5 based on the old lab 6.
// Better variable names, better prepared for some lab tasks. More changes may come
// but I call this version 1.0b2.
// 2017-12-04: Two fixes: Added command-lines (above), fixed a bug in computeImages
// that allocated too much memory. b3
// 2017-12-04: More fixes: Tightened up the kernel with edge clamping.
// Less code, nicer result (no borders). Cleaned up some messed up X and Y. b4

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#ifdef __APPLE__
  #include <GLUT/glut.h>
  #include <OpenGL/gl.h>
#else
  #include <GL/glut.h>
#endif
#include "readppm.h"
#include "milli.h"

// Use these for setting shared memory size.
#define maxKernelSizeX 10
#define maxKernelSizeY 10

#define SIZE 32

//#define separable
//#define gaussian
#define median

__device__ int pooper(int *histogram, int kernelsize)
{
  int pixelCounter = 0;
  int value;
  int prevValue = 0;
	for(int i = 0; i < 256; i++) {
		// Check if we have traversed half of the kernel (i.e. where the median should be)
		// Since a lot of values will be zero in the histogram, we need to count
		// the number of elements actually containing "real" information
		pixelCounter += histogram[i];
		if(pixelCounter > kernelsize/2) {
			value = (prevValue != 0) ? (i + prevValue)/2 : i;	// Return the median
			break;
		}
		prevValue = (histogram[i] != 0) ? i : prevValue;
	}
	return value;
}


__global__ void filter(unsigned char *image, unsigned char *out, const unsigned int imagesizex, const unsigned int imagesizey, const int kernelsizex, const int kernelsizey)
{
  // map from blockIdx to pixel position
  // I.e. original image base coordinate
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;

  // ****** Allocate Shared Memory ****** //
  // We need a MAXMEMSIZE since kernelsize specify a filter of size (2*kernelsize + 1)
  const int MAXMEMSIZEX = 2 * SIZE + 1;
  const int MAXMEMSIZEY = 2 * SIZE + 1;
  __shared__ unsigned char smem[MAXMEMSIZEX*MAXMEMSIZEY*3]; // 3 for RGB

  // Define our shared memory block
  // (Avoid using branching by using max and min)
  // ***** THE PROBLEM SEEMS TO BE LOCATED HERE ***** //
  int memBlockStartX = max(0, (int)(blockIdx.x*blockDim.x) - kernelsizex);
  int memBlockStartY = max(0, (int)(blockIdx.y*blockDim.y) - kernelsizey);
  int memBlockEndX = min(imagesizex-1, memBlockStartX + (int)blockDim.x + (2*kernelsizex)); // Using different constants in the last paranthesis seems to alter the result the most
  int memBlockEndY = min(imagesizey-1, memBlockStartY + (int)blockDim.y + (2*kernelsizey)); // These values provide a nice result for separable filters though...

  // Define thread memory by calculating shared memory block size to actual block size ratio
  int memBlockSize = (memBlockEndX - memBlockStartX + 1) * (memBlockEndY - memBlockStartY + 1);
  int blocksize = (blockDim.x * blockDim.y)/4;
  int threadMem = (int)(memBlockSize/(blocksize));

  int memSizeX = memBlockEndX - memBlockStartX + 1;

  // Load the ammount of pixel memory allowed for each thread to shared memory
  for(int i = 0; i <= threadMem; i++) {// TODO: Find corresponding image data to memory index, no RGB?
    // (Remember, our Shared Memory is a 1D array)
    // Traverse our shared memory block
    int memIndex = (threadIdx.x + threadIdx.y * memSizeX + i * blocksize);
    int memCurrentX = memIndex % memSizeX;
    int memCurrentY = (int)((memIndex - memCurrentX) / memSizeX);
    // TODO: Add RGB functionality
    memIndex *= 3;

    // Map to image index
    int imgX = memBlockStartX + memCurrentX;
    int imgY = memBlockStartY + memCurrentY;
    int imgIndex = 3 * (imgX + imgY * imagesizex);

    if( memIndex <=  3 * memBlockSize ) {

      smem[memIndex+0] = image[imgIndex];
      smem[memIndex+1] = image[imgIndex+1];
      smem[memIndex+2] = image[imgIndex+2];
    }
  }

  __syncthreads();

  // ****** Actual Filter ****** //
  int dy, dx;
  #ifndef median
  unsigned int sumx, sumy, sumz;
	sumx=0;sumy=0;sumz=0;
  #endif
  // Shared Memory coordinates
  int sx = x - memBlockStartX;
  int sy = y - memBlockStartY;

  #ifdef gaussian
    // Define gaussian kernel weights for 5 x 5 filter kernel
    int weights[] = {1, 4, 6, 4, 1};
    int divby = 16;
  #else
    int divby = (2*kernelsizex+1) * (2*kernelsizex+1); // Works for box filters only!
  #endif

	if (x < imagesizex && y < imagesizey) // If inside image
	{
    #ifdef median
      // Median filtering can be done without sorting is we use a histogram instead
      int histogramX[256];
      int histogramY[256];
      int histogramZ[256];
      for(int i = 0; i < 256; i++) {
        histogramX[i] = 0;
        histogramY[i] = 0;
        histogramZ[i] = 0;
      }
    #endif


  // Filter kernel

	for(dy=-kernelsizey;dy<=kernelsizey;dy++)
		for(dx=-kernelsizex;dx<=kernelsizex;dx++)
		{
			// Use max and min to avoid branching!
      int xx = min(max(sx+dx, 0), memBlockEndX);
      int yy = min(max(sy+dy, 0), memBlockEndY);

      int sharedIndex = 3* (xx + memSizeX*yy);

      #ifdef gaussian
        // For gaussian filter we use the stencil to filter
        int stencil = weights[dx+dy+2];
        sumx += stencil * smem[sharedIndex];
        sumy += stencil * smem[sharedIndex+1];
        sumz += stencil * smem[sharedIndex+2];
      #elif defined(median)
        histogramX[(int)(smem[sharedIndex])]  += 1;
        histogramY[(int)(smem[sharedIndex+1])]+= 1;
        histogramZ[(int)(smem[sharedIndex+2])]+= 1;
      #else
        // Instead, collect data from Shared Memory rather than Global Memory
			  sumx += smem[sharedIndex];
        sumy += smem[sharedIndex+1];
        sumz += smem[sharedIndex+2];
      #endif
		}

  #ifdef median
  out[(y*imagesizex+x)*3+0] = pooper(histogramX, divby);
  out[(y*imagesizex+x)*3+1] = pooper(histogramY, divby);
  out[(y*imagesizex+x)*3+2] = pooper(histogramZ, divby);
  #else
	 out[(y*imagesizex+x)*3+0] = sumx/divby;
	 out[(y*imagesizex+x)*3+1] = sumy/divby;
	 out[(y*imagesizex+x)*3+2] = sumz/divby;
  #endif
	}
}

// Global variables for image data
unsigned char *image, *pixels, *dev_bitmap, *dev_input, *dev_temp;
unsigned int imagesizey, imagesizex; // Image size

////////////////////////////////////////////////////////////////////////////////
// MAIN COMPUTATION FUNCTION
////////////////////////////////////////////////////////////////////////////////
void computeImages(int kernelsizex, int kernelsizey)
{
	if (kernelsizex > maxKernelSizeX || kernelsizey > maxKernelSizeY)
	{
		printf("Kernel size out of bounds!\n");
		return;
	}

  // ***** OUR BLOCKSIZE VARIABLE IS PROVIDING SOME WEIRD OUTPUTS IF CHANGED AS WELL ****** //
  // For boxfilters we cannot use a blocksize >= 10
  int blocksize = 4;

	pixels = (unsigned char *) malloc(imagesizex*imagesizey*3);
	cudaMalloc( (void**)&dev_input, imagesizex*imagesizey*3);
	cudaMemcpy( dev_input, image, imagesizey*imagesizex*3, cudaMemcpyHostToDevice );
	cudaMalloc( (void**)&dev_bitmap, imagesizex*imagesizey*3);

  cudaMalloc( (void**)&dev_temp, imagesizex * imagesizey * 3);
    #if defined(gaussian) || defined(separable)
      // If we want to use separable filter kernels, run this code
      dim3 grid1(imagesizex/(blocksize), imagesizey);
      dim3 blockGrid1(blocksize,1);
      dim3 grid2(imagesizex*3, imagesizey/blocksize);
      dim3 blockGrid2(3, blocksize);
      filter<<<grid1, blockGrid1>>>(dev_input, dev_temp, imagesizex, imagesizey, kernelsizex, 0);   // Output goes into temp variable, no kernelsizey
      filter<<<grid2, blockGrid2>>>(dev_temp, dev_bitmap, imagesizex, imagesizey, 0, kernelsizey);  // Input is temp variable here, no kernelsizex
    #else
      // "Normal" box-filter kernel
      dim3 grid(imagesizex/ blocksize, imagesizey / blocksize);
      dim3 blockGrid(3*blocksize, blocksize);
      filter<<<grid, blockGrid>>>(dev_input, dev_bitmap, imagesizex, imagesizey, kernelsizex, kernelsizey); // Awful load balance
    #endif

	cudaThreadSynchronize();
//	Check for errors!
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)
        printf("Error: %s\n", cudaGetErrorString(err));
	cudaMemcpy( pixels, dev_bitmap, imagesizey*imagesizex*3, cudaMemcpyDeviceToHost );
	cudaFree( dev_bitmap );
	cudaFree( dev_input );
  #ifdef separable
    cudaFree( dev_temp);
  #endif
}

// Display images
void Draw()
{
// Dump the whole picture onto the screen.
	glClearColor( 0.0, 0.0, 0.0, 1.0 );
	glClear( GL_COLOR_BUFFER_BIT );

	if (imagesizey >= imagesizex)
	{ // Not wide - probably square. Original left, result right.
		glRasterPos2f(-1, -1);
		glDrawPixels( imagesizex, imagesizey, GL_RGB, GL_UNSIGNED_BYTE, image );
		glRasterPos2i(0, -1);
		glDrawPixels( imagesizex, imagesizey, GL_RGB, GL_UNSIGNED_BYTE,  pixels);
	}
	else
	{ // Wide image! Original on top, result below.
		glRasterPos2f(-1, -1);
		glDrawPixels( imagesizex, imagesizey, GL_RGB, GL_UNSIGNED_BYTE, pixels );
		glRasterPos2i(-1, 0);
		glDrawPixels( imagesizex, imagesizey, GL_RGB, GL_UNSIGNED_BYTE, image );
	}
	glFlush();
}

// Main program, inits
int main( int argc, char** argv)
{
  printf("\n*----------- PROGRAM INFO -----------* \n\n");
	glutInit(&argc, argv);
	glutInitDisplayMode( GLUT_SINGLE | GLUT_RGBA );

	if (argc > 1)
		image = readppm(argv[1], (int *)&imagesizex, (int *)&imagesizey);
	else
    #ifdef median
		  image = readppm((char *)"maskros-noisy.ppm", (int *)&imagesizex, (int *)&imagesizey);
    #else
      image = readppm((char *)"img1.ppm", (int *)&imagesizex, (int *)&imagesizey);
    #endif
	if (imagesizey >= imagesizex)
		glutInitWindowSize( imagesizex*2, imagesizey );
	else
		glutInitWindowSize( imagesizex, imagesizey*2 );
	glutCreateWindow("Lab 5");
	glutDisplayFunc(Draw);

  int filterX = 5;
  int filterY = 5;
	ResetMilli();
	computeImages(filterX, filterY);
  int time = GetMicroseconds();

  printf("\n*----------- BENCHMARKING -----------*");
  #ifdef separable
    printf("\n\nSeparable filter");
  #elif defined gaussian
    printf("\n\nGaussian filter");
  #elif defined(median)
    printf("\n\nMedian filter");
  #else
    printf("\n\nBox filter\n");
  #endif
  printf("\n\nKernel size %ix%i", filterX, filterY);
	printf("\n\nFiltering took %i microseconds. \n\n", time );

// You can save the result to a file like this:
  writeppm("out.ppm", imagesizey, imagesizex, pixels);

	glutMainLoop();
	return 0;
}
