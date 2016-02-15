// Copyright (c) 2016, XMOS Ltd, All rights reserved
#include <xscope.h>
#include <platform.h>
#include <xs1.h>
#include <string.h>
#include <xclib.h>
#include <stdint.h>
#include "debug_print.h"

#include "fir_decimator.h"
#include "mic_array.h"
#include "mic_array_board_support.h"

#include "i2c.h"
#include "i2s.h"

//If the decimation factor is changed the the coefs array of decimator_config must also be changed.
#define DF 2    // Decimation Factor

on tile[0]:p_leds leds = DEFAULT_INIT;
on tile[0]:in port p_buttons =  XS1_PORT_4A;

on tile[0]: in port p_pdm_clk               = XS1_PORT_1E;
on tile[0]: in buffered port:32 p_pdm_mics  = XS1_PORT_8B;
on tile[0]: in port p_mclk                  = XS1_PORT_1F;
on tile[0]: clock pdmclk                    = XS1_CLKBLK_1;

out buffered port:32 p_i2s_dout[1]  = on tile[1]: {XS1_PORT_1P};
in port p_mclk_in1                  = on tile[1]: XS1_PORT_1O;
out buffered port:32 p_bclk         = on tile[1]: XS1_PORT_1M;
out buffered port:32 p_lrclk        = on tile[1]: XS1_PORT_1N;
out port p_pll_sync                 = on tile[1]: XS1_PORT_4D;
port p_i2c                          = on tile[1]: XS1_PORT_4E; // Bit 0: SCLK, Bit 1: SDA
port p_rst_shared                   = on tile[1]: XS1_PORT_4F; // Bit 0: DAC_RST_N, Bit 1: ETH_RST_N
clock mclk                          = on tile[1]: XS1_CLKBLK_3;
clock bclk                          = on tile[1]: XS1_CLKBLK_4;

// Based on the spreadsheet mic_array_das_beamformer_calcs.xls,
// which can be found in the root directory of this app
static const one_meter_thirty_degrees[6] = {0, 3, 8, 11, 8, 3};

static void set_dir(client interface led_button_if lb,
                    unsigned dir, unsigned delay[]) {

    for(unsigned i=0;i<13;i++)
        lb.set_led_brightness(i, 0);
    delay[0] = 5;
    for(unsigned i=0;i<6;i++)
        delay[i+1] = one_meter_thirty_degrees[(i - dir + 3 +6)%6];

    switch(dir){
    case 0:{
        lb.set_led_brightness(0, 255);
        lb.set_led_brightness(1, 255);
        break;
    }
    case 1:{
        lb.set_led_brightness(2, 255);
        lb.set_led_brightness(3, 255);
        break;
    }
    case 2:{
        lb.set_led_brightness(4, 255);
        lb.set_led_brightness(5, 255);
        break;
    }
    case 3:{
        lb.set_led_brightness(6, 255);
        lb.set_led_brightness(7, 255);
        break;
    }
    case 4:{
        lb.set_led_brightness(8, 255);
        lb.set_led_brightness(9, 255);
        break;
    }
    case 5:{
        lb.set_led_brightness(10, 255);
        lb.set_led_brightness(11, 255);
        break;
    }
    }
}

int data_0[4*THIRD_STAGE_COEFS_PER_STAGE*DF] = {0};
int data_1[4*THIRD_STAGE_COEFS_PER_STAGE*DF] = {0};
frame_audio audio[2];

void lores_DAS_fixed(streaming chanend c_ds_output[2],
        client interface led_button_if lb, chanend c_audio) {

    unsafe{
        unsigned buffer = 1;     // buffer index
        memset(audio, sizeof(frame_audio), 0);

        #define MAX_DELAY 16
        unsigned gain = 8;
        unsigned delay[7] = {0, 0, 0, 0, 0, 0, 0};
        int delay_buffer[MAX_DELAY][7];
        memset(delay_buffer, sizeof(int)*8*8, 0);
        unsigned delay_head = 0;
        unsigned dir = 0;
        set_dir(lb, dir, delay);

        decimator_config_common dcc = {0, 1, 0, 0, DF, g_third_stage_div_2_fir, 0, 0, DECIMATOR_NO_FRAME_OVERLAP, 2};
        decimator_config dc[2] = {
          {&dcc, data_0, {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4},
          {&dcc, data_1, {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4}
        };
        decimator_configure(c_ds_output, 2, dc);

        decimator_init_audio_frame(c_ds_output, 2, buffer, audio, dcc);

        while(1){

            frame_audio *current = decimator_get_next_audio_frame(c_ds_output, 2, buffer, audio, dcc);

            // Copy the current sample to the delay buffer
            for(unsigned i=0;i<7;i++)
                delay_buffer[delay_head][i] = current->data[i][0];

            // light the LED for the current direction
            int t;
            select {
                case lb.button_event():{
                    unsigned button;
                    e_button_state pressed;
                    lb.get_button_event(button, pressed);
                    if(pressed == BUTTON_PRESSED){
                        switch(button){
                        case 0:
                            dir--;
                            if(dir == -1)
                                dir = 5;
                            set_dir(lb, dir, delay);
                            debug_printf("dir %d\n", dir+1);
                            for(unsigned i=0;i<7;i++)
                                debug_printf("delay[%d] = %d\n", i, delay[i]);
                            debug_printf("\n");
                            break;

                        case 1:
                            gain = ((gain<<3) - gain)>>3;
                            debug_printf("gain: %d\n", gain);
                            break;

                        case 2:
                            if (gain == 0)
                                gain = 5;
                            gain = ((gain<<3) + gain)>>3;
                            debug_printf("gain: %d\n", gain);
                            break;

                        case 3:
                            dir++;
                            if(dir == 6)
                                dir = 0;
                            set_dir(lb, dir, delay);
                            debug_printf("dir %d\n", dir+1);
                            for(unsigned i=0;i<7;i++)
                                debug_printf("delay[%d] = %d\n", i, delay[i]);
                            debug_printf("\n");
                            break;
                        }
                    }
                    break;
                }
                default:break;
            }
            int output = 0;
            for(unsigned i=0;i<7;i++)
                output += (delay_buffer[(delay_head - delay[i])%MAX_DELAY][i]>>3);
            output *= gain;

            // Update the center LED with a volume indicator
            unsigned value = output >> 20;
            unsigned magnitude = (value * value) >> 8;
            lb.set_led_brightness(12, magnitude);

            c_audio <: output;
            c_audio <: output;
            delay_head++;
            delay_head%=MAX_DELAY;
        }
    }
}

#define OUTPUT_SAMPLE_RATE (96000/DF)
#define MASTER_CLOCK_FREQUENCY 24576000

[[distributable]]
void i2s_handler(server i2s_callback_if i2s,
                 client i2c_master_if i2c, chanend c_audio) {
  p_rst_shared <: 0xF;

  i2c_regop_res_t res;
  int i = 0x4A;
  uint8_t data = i2c.read_reg(i, 1, res);

  data = i2c.read_reg(i, 0x02, res);
  data |= 1;
  res = i2c.write_reg(i, 0x02, data); // Power down

  // Setting MCLKDIV2 high if using 24.576MHz.
  data = i2c.read_reg(i, 0x03, res);
  data |= 1;
  res = i2c.write_reg(i, 0x03, data);

  data = 0b01110000;
  res = i2c.write_reg(i, 0x10, data);

  data = i2c.read_reg(i, 0x02, res);
  data &= ~1;
  res = i2c.write_reg(i, 0x02, data); // Power up

#define CS2100_I2C_DEVICE_ADDR      (0x9c>>1)
  res = i2c.write_reg(CS2100_I2C_DEVICE_ADDR, 0x3, 0); // Reset the PLL to use the aux out


  while (1) {
    select {
    case i2s.init(i2s_config_t &?i2s_config, tdm_config_t &?tdm_config):
      i2s_config.mode = I2S_MODE_LEFT_JUSTIFIED;
      i2s_config.mclk_bclk_ratio = (MASTER_CLOCK_FREQUENCY/OUTPUT_SAMPLE_RATE)/64;
      break;

    case i2s.restart_check() -> i2s_restart_t restart:
      restart = I2S_NO_RESTART;
      break;

    case i2s.receive(size_t index, int32_t sample):
      break;

    case i2s.send(size_t index) -> int32_t sample:
      c_audio:> sample;
      break;
    }
  }
}

int main() {

    i2s_callback_if i_i2s;
    i2c_master_if i_i2c[1];
    chan c_audio;
    par{

        on tile[1]: {
          configure_clock_src(mclk, p_mclk_in1);
          start_clock(mclk);
          i2s_master(i_i2s, p_i2s_dout, 1, null, 0, p_bclk, p_lrclk, bclk, mclk);
        }

        on tile[1]:  [[distribute]]i2c_master_single_port(i_i2c, 1, p_i2c, 100, 0, 1, 0);
        on tile[1]:  [[distribute]]i2s_handler(i_i2s, i_i2c[0], c_audio);

        on tile[0]: {
            configure_clock_src_divide(pdmclk, p_mclk, 4);
            configure_port_clock_output(p_pdm_clk, pdmclk);
            configure_in_port(p_pdm_mics, pdmclk);
            start_clock(pdmclk);

            streaming chan c_4x_pdm_mic[2];
            streaming chan c_ds_output[2];

            interface led_button_if lb[1];

            par {
                button_and_led_server(lb, 1, leds, p_buttons);
                pdm_rx(p_pdm_mics, c_4x_pdm_mic[0], c_4x_pdm_mic[1]);
                decimate_to_pcm_4ch(c_4x_pdm_mic[0], c_ds_output[0]);
                decimate_to_pcm_4ch(c_4x_pdm_mic[1], c_ds_output[1]);
                lores_DAS_fixed(c_ds_output, lb[0], c_audio);
            }
        }
    }
    return 0;
}